module SourceDocuments
  class UploadService
    MAX_FILE_SIZE = 10.megabytes

    def self.call(user:, pdf_param:)
      new(user: user, pdf_param: pdf_param).call
    end

    def initialize(user:, pdf_param:)
      @user = user
      @pdf_param = pdf_param
    end

    def call
      return failure("Please select a PDF file to upload.", :missing_file) if pdf_param.nil?
      return failure("Only PDF files are supported.", :invalid_file_type) unless pdf?
      return failure("File size exceeds the 10MB limit.", :file_too_large) if pdf_param.size > MAX_FILE_SIZE

      file_bytes = pdf_param.read
      pdf_param.rewind if pdf_param.respond_to?(:rewind)
      sha256 = Digest::SHA256.hexdigest(file_bytes)

      existing = user.source_documents.find_by(attachment_sha256: sha256)
      if existing
        return existing_result(existing)
      end

      begin
        source_document = user.source_documents.transaction do
          doc = user.source_documents.create!(
            attachment_file: file_bytes,
            attachment_filename: pdf_param.original_filename,
            attachment_content_type: pdf_param.content_type,
            attachment_sha256: sha256,
            status: "processing",
            document_type: "unknown"
          )
          user.increment_inbox_revision!
          doc
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        if e.is_a?(ActiveRecord::RecordNotUnique) || (e.is_a?(ActiveRecord::RecordInvalid) && e.record.errors[:attachment_sha256].any?)
          existing = user.source_documents.find_by(attachment_sha256: sha256)
          return existing_result(existing) if existing
        end
        if e.is_a?(ActiveRecord::RecordInvalid)
          return failure("Upload failed: #{e.record.errors.full_messages.to_sentence}", :validation_error)
        else
          raise e
        end
      end

      ImportedTransactions::InboxBroadcastService.call(user: user, document: source_document)

      begin
        IngestSourceDocumentJob.perform_later(source_document.id)
      rescue => e
        source_document.transaction do
          source_document.update_columns(
            status: "failed",
            error_message: "Failed to queue ingestion job: #{e.message}"
          )
          user.increment_inbox_revision!
        end
        ImportedTransactions::InboxBroadcastService.call(user: user, document: source_document)
        raise e
      end

      success(source_document: source_document, upload_status: :queued)
    rescue => e
      Rails.logger.error("Upload document failed: #{e.message}\n#{e.backtrace.join("\n")}")
      failure("Upload failed: An unexpected error occurred while processing the file.", :unexpected_error)
    end

    private

      attr_reader :user, :pdf_param

      def existing_result(existing)
        upload_status = case existing.status
        when "success" then :already_processed
        when "processing" then :already_processing
        when "failed" then :retry_required
        else :already_processing
        end

        success(source_document: existing, upload_status: upload_status)
      end

      def pdf?
        file = pdf_param
        return false unless file

        header = file.read(5)
        file.rewind
        header == "%PDF-"
      end

      def success(source_document:, upload_status:)
        ServiceResult.success(source_document: source_document, upload_status: upload_status)
      end

      def failure(error, code)
        ServiceResult.failure(error: error, code: code)
      end
  end
end
