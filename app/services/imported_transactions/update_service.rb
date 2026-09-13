module ImportedTransactions
  class UpdateService
    def self.call(user:, transaction:, params:)
      new(user: user, transaction: transaction, params: params).call
    end

    def initialize(user:, transaction:, params:)
      @user = user
      @transaction = transaction
      @params = params
    end

    def call
      return failure("Imported transaction was not found.", :not_found) unless transaction.user_id == user.id

      res = transaction.with_lock do
        return failure("Cannot update a confirmed imported transaction", :immutable) if transaction.confirmed?

        submitted_lock_version = params[:lock_version] || params["lock_version"]
        if submitted_lock_version.present? && transaction.lock_version.to_s != submitted_lock_version.to_s
          return failure("This transaction was updated in another session. Please reload to review the latest changes.", :conflict)
        end

        transaction.assign_attributes(params)
        recompute_matching_status

        if transaction.save
          user.increment_inbox_revision!
          success(transaction)
        else
          failure(transaction.errors.full_messages.to_sentence, :validation_error)
        end
      end

      if res.success?
        ImportedTransactions::InboxBroadcastService.call(user: user, updated_transaction_id: transaction.id)
      end

      res
    rescue ActiveRecord::RecordNotFound
      failure("Imported transaction was not found.", :gone)
    rescue ActiveRecord::StaleObjectError
      failure("This transaction was updated in another session. Please reload to review the latest changes.", :conflict)
    rescue ActiveRecord::RecordNotUnique
      failure("This transaction reference has already been imported for this payment method.", :duplicate_external_transaction)
    end

    private

      attr_reader :user, :transaction, :params

      def recompute_matching_status
        return if transaction.confirmed?

        if transaction.matched_party_id.present? && transaction.matched_tenancy_id.present?
          transaction.status = "matched"
        elsif matching_fields_changed?
          transaction.status = "unmatched"
        end
        # Preserve status if match fields were not modified
      end

      def matching_fields_changed?
        transaction.matched_party_id_changed? || transaction.matched_tenancy_id_changed?
      end

      def success(data)
        ServiceResult.success(transaction: data)
      end

      def failure(error, code)
        ServiceResult.failure(error: error, code: code)
      end
  end
end
