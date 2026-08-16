module PaymentDocuments
  class DestroyService
    def self.call(user:, document:)
      new(user:, document:).call
    end

    def initialize(user:, document:)
      @user = user
      @document = document
    end

    def call
      return failure("Document was not found.", :not_found) unless document.user_id == user.id

      document.transaction do
        document.lock!
        ingestions = document.payment_ingestions.lock("FOR UPDATE").to_a

        if ingestions.any?(&:confirmed?)
          return failure("Cannot delete document with confirmed payment ingestions", :immutable)
        end

        document.destroy!
        success(document)
      end
    rescue ActiveRecord::RecordNotDestroyed => e
      failure(e.record.errors.full_messages.to_sentence.presence || "Cannot delete document", :destroy_failed)
    end

    private

      attr_reader :user, :document

      def success(data)
        ServiceResult.success(data)
      end

      def failure(error, code)
        ServiceResult.failure(error:, code:)
      end
  end
end
