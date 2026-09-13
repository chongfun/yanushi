module ImportedTransactions
  class DestroyService
    def self.call(user:, transaction:, lock_version: nil)
      new(user: user, transaction: transaction, lock_version: lock_version).call
    end

    def initialize(user:, transaction:, lock_version: nil)
      @user = user
      @transaction = transaction
      @lock_version = lock_version
    end

    def call
      return failure("Imported transaction was not found.", :not_found) unless transaction.user_id == user.id

      res = transaction.with_lock do
        return failure("Cannot delete a confirmed imported transaction", :immutable) if transaction.confirmed?

        if lock_version.present? && transaction.lock_version.to_s != lock_version.to_s
          return failure("This transaction was updated in another session. Please reload to review the latest changes.", :conflict)
        end

        transaction.destroy!
        user.increment_inbox_revision!
        success(transaction)
      end

      if res.success?
        Turbo::StreamsChannel.broadcast_remove_to(
          [ user, :inbox ],
          target: "imported_transaction_#{transaction.id}"
        )
        ImportedTransactions::InboxBroadcastService.call(user: user)
      end

      res
    rescue ActiveRecord::RecordNotFound
      failure("Imported transaction was not found.", :gone)
    rescue ActiveRecord::StaleObjectError
      failure("This transaction was updated in another session. Please reload to review the latest changes.", :conflict)
    rescue ActiveRecord::RecordNotDestroyed => e
      failure(e.record.errors.full_messages.to_sentence.presence || "Cannot delete imported transaction", :destroy_failed)
    end

    private

      attr_reader :user, :transaction, :lock_version

      def success(data)
        ServiceResult.success(transaction: data)
      end

      def failure(error, code)
        ServiceResult.failure(error: error, code: code)
      end
  end
end
