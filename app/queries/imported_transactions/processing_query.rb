module ImportedTransactions
  class ProcessingQuery
    ProcessingResult = Data.define(
      :processing_documents,
      :failed_documents,
      :processing_count,
      :failed_count,
      :review_count,
      :history_count,
      :inbox_revision
    )

    def initialize(user:)
      @user = user
    end

    def call
      5.times do
        before_revision = user.reload.inbox_revision

        proc_docs = user.source_documents.processing.order(created_at: :desc).to_a
        fail_docs = user.source_documents.failed.order(created_at: :desc).to_a
        rev_count = user.imported_transactions.reviewable.count
        hist_count = user.imported_transactions.confirmed.count

        after_revision = user.reload.inbox_revision
        next unless before_revision == after_revision

        return ProcessingResult.new(
          processing_documents: proc_docs,
          failed_documents: fail_docs,
          processing_count: proc_docs.size,
          failed_count: fail_docs.size,
          review_count: rev_count,
          history_count: hist_count,
          inbox_revision: after_revision
        )
      end

      User.transaction do
        user.lock!

        proc_docs = user.source_documents.processing.order(created_at: :desc).to_a
        fail_docs = user.source_documents.failed.order(created_at: :desc).to_a
        rev_count = user.imported_transactions.reviewable.count
        hist_count = user.imported_transactions.confirmed.count
        revision = user.inbox_revision

        ProcessingResult.new(
          processing_documents: proc_docs,
          failed_documents: fail_docs,
          processing_count: proc_docs.size,
          failed_count: fail_docs.size,
          review_count: rev_count,
          history_count: hist_count,
          inbox_revision: revision
        )
      end
    end

    private

      attr_reader :user
  end
end
