module PaymentIngestions
  class IndexQuery
    Result = Data.define(
      :reviewable_ingestions,
      :confirmed_ingestions,
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
      confirmed_scope = confirmed_ingestions_scope
      total_confirmed_count = confirmed_scope.count
      total_pages = (total_confirmed_count.to_f / per_page).ceil
      page = [ page, total_pages ].min if total_pages > 0

      Result.new(
        reviewable_ingestions: reviewable_ingestions,
        confirmed_ingestions: confirmed_scope.order(created_at: :desc).limit(per_page).offset((page - 1) * per_page),
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

    def reviewable_ingestions
      user.payment_ingestions
          .includes(:tenant, lease: :rental_property)
          .reviewable
          .order(created_at: :desc)
    end

    def confirmed_ingestions_scope
      user.payment_ingestions
          .includes(:tenant, lease: :rental_property)
          .confirmed
    end

    def processing_documents
      user.payment_documents
          .processing
          .select(*document_columns)
          .order(created_at: :desc)
    end

    def failed_documents
      user.payment_documents
          .failed
          .select(*document_columns)
          .order(created_at: :desc)
    end

    def document_columns
      [ :id, :user_id, :attachment_filename, :attachment_content_type, :status, :error_message, :created_at, :updated_at ]
    end
  end
end
