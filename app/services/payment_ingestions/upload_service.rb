module PaymentIngestions
  class UploadService
    MAX_FILE_SIZE = 10.megabytes

    def self.call(user:, pdf_param:)
      new(user:, pdf_param:).call
    end

    def initialize(user:, pdf_param:)
      @user = user
      @pdf_param = pdf_param
    end

    def call
      return failure("Please select a PDF file to upload.", :missing_file) if pdf_param.nil?
      return failure("Only PDF files are supported.", :invalid_file_type) unless pdf?
      return failure("File size exceeds the 10MB limit.", :file_too_large) if pdf_param.size > MAX_FILE_SIZE

      payment_document = user.payment_documents.create!(
        attachment_file: pdf_param.read,
        attachment_filename: pdf_param.original_filename,
        attachment_content_type: pdf_param.content_type,
        status: :processing
      )

      IngestPaymentDocumentJob.perform_later(payment_document.id)
      success(payment_document)
    rescue ActiveRecord::RecordInvalid => e
      failure("Upload failed: #{e.record.errors.full_messages.to_sentence}", :validation_error)
    rescue => e
      Rails.logger.error("Upload document failed: #{e.message}\n#{e.backtrace.join("\n")}")
      failure("Upload failed: An unexpected error occurred while processing the file.", :unexpected_error)
    end

    private

    attr_reader :user, :pdf_param

    def pdf?
      header = pdf_param.read(5)
      pdf_param.rewind
      header == "%PDF-"
    end

    def success(data)
      ServiceResult.new(success: true, data:, error: nil, code: nil)
    end

    def failure(error, code)
      ServiceResult.new(success: false, data: nil, error:, code:)
    end
  end
end
