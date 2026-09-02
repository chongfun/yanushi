module ImportedTransactions
  class InboxQuery
    InboxResult = Data.define(
      :reviewable_transactions,
      :review_count,
      :processing_documents,
      :failed_documents,
      :processing_count,
      :failed_count,
      :history_count,
      :updated_transaction,
      :updated_transaction_position,
      :next_transaction,
      :inbox_revision
    )

    def initialize(user:, load_records: true, updated_transaction_id: nil)
      @user = user
      @load_records = load_records
      @updated_transaction_id = updated_transaction_id
    end

    def call
      5.times do
        before_revision = user.reload.inbox_revision

        reviewables, rev_count, next_txn = fetch_reviewables
        proc_count = processing_count
        fail_count = failed_count
        hist_count = history_count
        updated_txn = fetch_updated_transaction
        position = fetch_updated_transaction_position(updated_txn)

        after_revision = user.reload.inbox_revision
        next unless before_revision == after_revision

        return InboxResult.new(
          reviewable_transactions: reviewables,
          review_count: rev_count,
          processing_documents: [],
          failed_documents: [],
          processing_count: proc_count,
          failed_count: fail_count,
          history_count: hist_count,
          updated_transaction: updated_txn,
          updated_transaction_position: position,
          next_transaction: next_txn,
          inbox_revision: after_revision
        )
      end

      # Fallback under row lock if retry limit reached
      User.transaction do
        user.lock!

        reviewables, rev_count, next_txn = fetch_reviewables
        proc_count = processing_count
        fail_count = failed_count
        hist_count = history_count
        updated_txn = fetch_updated_transaction
        position = fetch_updated_transaction_position(updated_txn)
        revision = user.inbox_revision

        InboxResult.new(
          reviewable_transactions: reviewables,
          review_count: rev_count,
          processing_documents: [],
          failed_documents: [],
          processing_count: proc_count,
          failed_count: fail_count,
          history_count: hist_count,
          updated_transaction: updated_txn,
          updated_transaction_position: position,
          next_transaction: next_txn,
          inbox_revision: revision
        )
      end
    end

    private

      attr_reader :user, :load_records, :updated_transaction_id

      def fetch_reviewables
        if load_records
          records = user.imported_transactions
                        .includes(:matched_party, :source_document, matched_tenancy: { rentable_unit: :property })
                        .reviewable
                        .order(created_at: :desc, id: :desc)
                        .to_a
          [ records, records.size, records.first ]
        else
          next_txn = user.imported_transactions
                         .reviewable
                         .includes(:matched_party, :source_document, matched_tenancy: { rentable_unit: :property })
                         .order(created_at: :desc, id: :desc)
                         .first
          [ [], user.imported_transactions.reviewable.count, next_txn ]
        end
      end

      def fetch_updated_transaction
        return nil unless updated_transaction_id

        user.imported_transactions
            .reviewable
            .includes(:matched_party, :source_document, matched_tenancy: { rentable_unit: :property })
            .find_by(id: updated_transaction_id)
      end

      def fetch_updated_transaction_position(updated_txn)
        return nil unless updated_txn

        ahead_count = user.imported_transactions
                          .reviewable
                          .where(
                            "created_at > :created_at OR (created_at = :created_at AND id > :id)",
                            created_at: updated_txn.created_at,
                            id: updated_txn.id
                          )
                          .count
        ahead_count + 1
      end

      def processing_count
        user.source_documents.processing.count
      end

      def failed_count
        user.source_documents.failed.count
      end

      def history_count
        user.imported_transactions.confirmed.count
      end
  end
end
