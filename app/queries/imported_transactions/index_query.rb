module ImportedTransactions
  class IndexQuery
    Result = Data.define(
      :reviewable_transactions,
      :confirmed_transactions,
      :processing_documents,
      :failed_documents,
      :page,
      :per_page,
      :total_pages,
      :total_confirmed_count
    )

    def initialize(user:)
      @user = user
    end

    def call(page: 1, per_page: 20)
      page = [ page.to_i, 1 ].max
      confirmed_scope = confirmed_transactions_scope
      total_confirmed_count = confirmed_scope.count
      total_pages = (total_confirmed_count.to_f / per_page).ceil
      page = [ page, total_pages ].min if total_pages > 0

      Result.new(
        reviewable_transactions: reviewable_transactions,
        confirmed_transactions: confirmed_scope.order(created_at: :desc).limit(per_page).offset((page - 1) * per_page),
        processing_documents: processing_documents,
        failed_documents: failed_documents,
        page: page,
        per_page: per_page,
        total_pages: total_pages,
        total_confirmed_count: total_confirmed_count
      )
    end

    private

      attr_reader :user

      def reviewable_transactions
        user.imported_transactions
            .includes(:matched_party, :source_document, matched_tenancy: { rentable_unit: :property })
            .reviewable
            .order(created_at: :desc)
      end

      def confirmed_transactions_scope
        user.imported_transactions
            .includes(:matched_party, :source_document, :confirmed_source, matched_tenancy: { rentable_unit: :property })
            .confirmed
      end

      def processing_documents
        user.source_documents
            .processing
            .select(*document_columns)
            .order(created_at: :desc)
      end

      def failed_documents
        user.source_documents
            .failed
            .select(*document_columns)
            .order(created_at: :desc)
      end

      def document_columns
        [ :id, :user_id, :attachment_filename, :attachment_content_type, :status, :error_message, :created_at, :updated_at ]
      end
  end
end
