module ImportedTransactions
  class ConfirmService
    def self.call(user:, transaction:, create_alias: false)
      new(user: user, transaction: transaction, create_alias: create_alias).call
    end

    def initialize(user:, transaction:, create_alias: false)
      @user = user
      @transaction = transaction
      @create_aliases = create_alias
    end

    def call
      return failure("Imported transaction was not found.", :not_found) unless transaction.user_id == user.id

      confirmed_source = nil # : untyped
      failure_result = nil # : (Dry::Monads::Result::Failure | Dry::Monads::Result::Success)?

      transaction.transaction do
        transaction.source_document&.lock!
        transaction.lock!
        transaction.reload

        if transaction.confirmed?
          if transaction.confirmed_source.present?
            confirmed_source = transaction.confirmed_source
            next
          else
            failure_result = failure("Already confirmed but confirmed source record is missing", :confirmation_error)
            raise ActiveRecord::Rollback
          end
        end

        if transaction.unknown?
          failure_result = failure("Transaction requires classification before confirmation", :classification_required)
          raise ActiveRecord::Rollback
        end

        unless transaction.confirmable?
          failure_result = failure("Cannot confirm: missing required fields or invalid state", :not_confirmable)
          raise ActiveRecord::Rollback
        end

        dispatch_result = case transaction.transaction_kind
        when "tenant_receipt"
          confirm_receipt
        when "security_deposit"
          confirm_security_deposit
        else
          failure("Transaction requires classification before confirmation", :classification_required)
        end

        unless dispatch_result.success?
          failure_result = dispatch_result
          raise ActiveRecord::Rollback
        end

        created_source = dispatch_result.value!.data[:source]
        create_party_aliases if create_aliases?

        transaction.update!(status: "confirmed", confirmed_source: created_source)
        confirmed_source = created_source
      end

      return failure_result if failure_result

      success(confirmed_source)
    rescue ActiveRecord::RecordNotUnique
      failure("This transaction has already been recorded in another confirmed source.", :duplicate)
    rescue ActiveRecord::RecordNotFound
      failure("Imported transaction was not found.", :not_found)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, :validation_error)
    end

    private

      attr_reader :user, :transaction

      def confirm_receipt
        result = Receipts::CreateService.call(
          tenancy: transaction.matched_tenancy,
          payer_party: transaction.matched_party,
          amount_cents: transaction.amount_cents,
          received_on: transaction.occurred_on,
          payment_method: transaction.payment_method,
          external_reference: transaction.external_reference
        )

        if result.success?
          ServiceResult.success(source: result.value!.data[:receipt])
        else
          result
        end
      end

      def confirm_security_deposit
        tenancy = transaction.matched_tenancy
        deposit = tenancy&.security_deposit
        unless deposit
          return failure(
            "No security-deposit requirement exists for this tenancy. Set up the security deposit before confirming this import.",
            :missing_security_deposit
          )
        end

        result = SecurityDepositTransactions::ReceiveService.call(
          security_deposit: deposit,
          party: transaction.matched_party,
          amount_cents: transaction.amount_cents,
          occurred_on: transaction.occurred_on,
          external_reference: transaction.external_reference
        )

        if result.success?
          ServiceResult.success(source: result.value!.data[:transaction])
        else
          result
        end
      end

      def create_party_aliases
        create_party_alias(transaction.payer_name)
        create_party_alias(transaction.payer_username)
      end

      def create_aliases?
        @create_aliases
      end

      def create_party_alias(alias_name)
        party = transaction.matched_party
        return unless party&.alias_candidate?(alias_name)

        party.party_aliases.create!(alias_name: alias_name)
      end

      def success(data)
        ServiceResult.success(source: data, confirmed_source: data, transaction: transaction)
      end

      def failure(error, code)
        ServiceResult.failure(error: error, code: code)
      end
  end
end
