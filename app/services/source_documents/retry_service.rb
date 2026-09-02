module SourceDocuments
  class RetryService
    def self.call(user:, document:)
      new(user: user, document: document).call
    end

    def initialize(user:, document:)
      @user = user
      @document = document
    end

    def call
      return failure("Document was not found.", :not_found) unless document.user_id == user.id

      res = document.with_lock do
        document.reload

        if document.imported_transactions.where(status: "confirmed").exists?
          next failure("Cannot retry a document with confirmed transactions.", :immutable)
        end

        if document.success?
          next failure("Document has already been processed successfully.", :already_processed)
        end

        document.update!(status: "processing", error_message: nil)
        user.increment_inbox_revision!
        success(source_document: document)
      end

      if res.success?
        ImportedTransactions::InboxBroadcastService.call(user: user, document: document)

        begin
          IngestSourceDocumentJob.perform_later(document.id)
        rescue => e
          document.transaction do
            document.update_columns(status: "failed", error_message: "Failed to queue ingestion job: #{e.message}")
            user.increment_inbox_revision!
          end
          ImportedTransactions::InboxBroadcastService.call(user: user, document: document)
          return failure("Failed to queue document processing.", :enqueue_failed)
        end
      end

      res
    rescue ActiveRecord::RecordInvalid => e
      failure("Retry failed: #{e.record.errors.full_messages.to_sentence}", :validation_error)
    rescue => e
      Rails.logger.error("Retry document failed: #{e.message}\n#{e.backtrace.join("\n")}")
      failure("Retry failed: An unexpected error occurred.", :unexpected_error)
    end

    private

      attr_reader :user, :document

      def success(data)
        ServiceResult.success(data)
      end

      def failure(error, code)
        ServiceResult.failure(error: error, code: code)
      end
  end
end
