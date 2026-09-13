module ImportedTransactions
  class HistoryQuery
    HistoryResult = Data.define(
      :confirmed_transactions,
      :page,
      :per_page,
      :total_pages,
      :total_confirmed_count,
      :review_count,
      :processing_count,
      :failed_count,
      :history_count,
      :inbox_revision,
      :filters
    )

    def initialize(user:)
      @user = user
    end

    def call(page: 1, per_page: 20, filters: {})
      page = [ page.to_i, 1 ].max
      per_page = [ per_page.to_i, 1 ].max
      active_filters = normalize_filters(filters)

      5.times do
        before_revision = user.reload.inbox_revision

        confirmed_scope = apply_filters(confirmed_transactions_scope, active_filters)
        total_confirmed_count = confirmed_scope.count
        total_pages = total_confirmed_count.zero? ? 0 : (total_confirmed_count.to_f / per_page).ceil
        current_page = total_pages > 0 ? [ page, total_pages ].min : page

        transactions = confirmed_scope.order(occurred_on: :desc, created_at: :desc).limit(per_page).offset((current_page - 1) * per_page).to_a
        preload_confirmed_sources(transactions)

        rev_count = user.imported_transactions.reviewable.count
        proc_count = user.source_documents.processing.count
        fail_count = user.source_documents.failed.count
        hist_count = user.imported_transactions.confirmed.count

        after_revision = user.reload.inbox_revision
        next unless before_revision == after_revision

        return HistoryResult.new(
          confirmed_transactions: transactions,
          page: current_page,
          per_page: per_page,
          total_pages: total_pages,
          total_confirmed_count: total_confirmed_count,
          review_count: rev_count,
          processing_count: proc_count,
          failed_count: fail_count,
          history_count: hist_count,
          inbox_revision: after_revision,
          filters: active_filters
        )
      end

      User.transaction do
        user.lock!

        confirmed_scope = apply_filters(confirmed_transactions_scope, active_filters)
        total_confirmed_count = confirmed_scope.count
        total_pages = total_confirmed_count.zero? ? 0 : (total_confirmed_count.to_f / per_page).ceil
        current_page = total_pages > 0 ? [ page, total_pages ].min : page

        transactions = confirmed_scope.order(occurred_on: :desc, created_at: :desc).limit(per_page).offset((current_page - 1) * per_page).to_a
        preload_confirmed_sources(transactions)

        rev_count = user.imported_transactions.reviewable.count
        proc_count = user.source_documents.processing.count
        fail_count = user.source_documents.failed.count
        hist_count = user.imported_transactions.confirmed.count
        revision = user.inbox_revision

        HistoryResult.new(
          confirmed_transactions: transactions,
          page: current_page,
          per_page: per_page,
          total_pages: total_pages,
          total_confirmed_count: total_confirmed_count,
          review_count: rev_count,
          processing_count: proc_count,
          failed_count: fail_count,
          history_count: hist_count,
          inbox_revision: revision,
          filters: active_filters
        )
      end
    end

    private

      attr_reader :user

      def preload_confirmed_sources(transactions)
        receipts = transactions.map(&:confirmed_source).grep(Receipt)
        if receipts.any?
          ActiveRecord::Associations::Preloader.new(records: receipts, associations: { tenancy: :property }).call
        end

        deposit_txns = transactions.map(&:confirmed_source).grep(SecurityDepositTransaction)
        if deposit_txns.any?
          ActiveRecord::Associations::Preloader.new(records: deposit_txns, associations: { security_deposit: { tenancy: :property } }).call
        end
      end

      def confirmed_transactions_scope
        user.imported_transactions
            .includes(:matched_party, :source_document, :confirmed_source, matched_tenancy: { rentable_unit: :property })
            .confirmed
      end

      def normalize_filters(filters)
        return {} unless filters.is_a?(Hash) || filters.respond_to?(:to_h)

        raw = filters.to_h
        {
          search: raw[:search].presence || raw["search"].presence,
          payment_method: raw[:payment_method].presence || raw["payment_method"].presence
        }.compact
      end

      def apply_filters(scope, filters)
        scope = scope.where(payment_method: filters[:payment_method]) if filters[:payment_method].present?

        if filters[:search].present?
          query_pattern = "%#{ActiveRecord::Base.sanitize_sql_like(filters[:search])}%"
          scope = scope.left_joins(:matched_party).where(
            "imported_transactions.payer_name ILIKE :q OR " \
            "imported_transactions.payer_username ILIKE :q OR " \
            "imported_transactions.external_reference ILIKE :q OR " \
            "parties.display_name ILIKE :q",
            q: query_pattern
          )
        end

        scope
      end
  end
end
