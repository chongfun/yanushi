module ImportedTransactions
  class DestroyService
    def self.call(user:, transaction:)
      new(user: user, transaction: transaction).call
    end

    def initialize(user:, transaction:)
      @user = user
      @transaction = transaction
    end

    def call
      return failure("Imported transaction was not found.", :not_found) unless transaction.user_id == user.id

      transaction.with_lock do
        return failure("Cannot delete a confirmed imported transaction", :immutable) if transaction.confirmed?

        transaction.destroy!
        success(transaction)
      end
    rescue ActiveRecord::RecordNotDestroyed => e
      failure(e.record.errors.full_messages.to_sentence.presence || "Cannot delete imported transaction", :destroy_failed)
    end

    private

      attr_reader :user, :transaction

      def success(data)
        ServiceResult.success(transaction: data)
      end

      def failure(error, code)
        ServiceResult.failure(error: error, code: code)
      end
  end
end
