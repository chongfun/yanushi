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

      transaction.with_lock do
        return failure("Cannot update a confirmed imported transaction", :immutable) if transaction.confirmed?

        transaction.assign_attributes(params)
        recompute_matching_status

        if transaction.save
          success(transaction)
        else
          failure(transaction.errors.full_messages.to_sentence, :validation_error)
        end
      end
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
