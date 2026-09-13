module SourceDocuments
  class DestroyService
    def self.call(user:, document:)
      new(user: user, document: document).call
    end

    def initialize(user:, document:)
      @user = user
      @document = document
    end

    def call
      return failure("Document was not found.", :not_found) unless document.user_id == user.id

      deleted_document_id = document.id
      cascaded_txn_ids = [] # : Array[Integer]

      res = document.transaction do
        document.lock!
        txns = document.imported_transactions.lock("FOR UPDATE").to_a

        if txns.any?(&:confirmed?)
          next failure("Cannot delete document with confirmed transactions", :immutable)
        end

        cascaded_txn_ids = txns.map(&:id)
        document.destroy!
        user.increment_inbox_revision!
        success(document)
      end

      if res.success?
        ImportedTransactions::InboxBroadcastService.call(
          user: user,
          deleted_document_id: deleted_document_id,
          deleted_transaction_ids: cascaded_txn_ids
        )
      end
      res
    rescue ActiveRecord::RecordNotDestroyed => e
      failure(e.record.errors.full_messages.to_sentence.presence || "Cannot delete document", :destroy_failed)
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
