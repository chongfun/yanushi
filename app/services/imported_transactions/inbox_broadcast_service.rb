module ImportedTransactions
  class InboxBroadcastService
    def self.call(user:, document: nil, deleted_document_id: nil, deleted_transaction_ids: [], updated_transaction_id: nil)
      new(
        user: user,
        document: document,
        deleted_document_id: deleted_document_id,
        deleted_transaction_ids: deleted_transaction_ids,
        updated_transaction_id: updated_transaction_id
      ).call
    end

    def initialize(user:, document: nil, deleted_document_id: nil, deleted_transaction_ids: [], updated_transaction_id: nil)
      @user = user
      @document = document
      @deleted_document_id = deleted_document_id
      @deleted_transaction_ids = deleted_transaction_ids || []
      @updated_transaction_id = updated_transaction_id
    end

    def call
      needs_records = document&.status == "success"
      inbox_result = ImportedTransactions::InboxQuery.new(
        user: user,
        load_records: needs_records,
        updated_transaction_id: updated_transaction_id
      ).call
      history_count = inbox_result.history_count
      form_data = needs_records && inbox_result.review_count.positive? ? ImportedTransactions::FormDataQuery.new(user: user).call : nil
      empty_docs = [] # : Array[SourceDocument]
      processing_docs = document && document.status != "success" ? user.source_documents.processing.order(created_at: :desc).to_a : empty_docs
      failed_docs = document && document.status != "success" ? user.source_documents.failed.order(created_at: :desc).to_a : empty_docs

      Turbo::StreamsChannel.broadcast_render_to(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: {
          user: user,
          document: document,
          deleted_document_id: deleted_document_id,
          deleted_transaction_ids: deleted_transaction_ids,
          updated_transaction: inbox_result.updated_transaction,
          review_count: inbox_result.review_count,
          processing_count: inbox_result.processing_count,
          failed_count: inbox_result.failed_count,
          inbox_revision: inbox_result.inbox_revision,
          history_count: history_count,
          reviewable_transactions: inbox_result.reviewable_transactions,
          form_data: form_data,
          processing_documents: processing_docs,
          failed_documents: failed_docs
        }
      )
    end

    private

      attr_reader :user, :document, :deleted_document_id, :deleted_transaction_ids, :updated_transaction_id
  end
end
