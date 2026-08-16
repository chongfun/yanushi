module PaymentIngestions
  class DestroyService
    def self.call(user:, ingestion:)
      new(user:, ingestion:).call
    end

    def initialize(user:, ingestion:)
      @user = user
      @ingestion = ingestion
    end

    def call
      return failure("Payment ingestion was not found.", :not_found) unless ingestion.user_id == user.id

      ingestion.with_lock do
        return failure("Cannot delete a confirmed payment ingestion", :immutable) if ingestion.confirmed?

        ingestion.destroy!
        success(ingestion)
      end
    rescue ActiveRecord::RecordNotDestroyed => e
      failure(e.record.errors.full_messages.to_sentence.presence || "Cannot delete payment ingestion", :destroy_failed)
    end

    private

      attr_reader :user, :ingestion

      def success(data)
        ServiceResult.success(data)
      end

      def failure(error, code)
        ServiceResult.failure(error:, code:)
      end
  end
end
