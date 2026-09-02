module ImportedTransactions
  class ConfirmService
    def self.call(user:, transaction:, params: {}, create_alias: false, requested_alias: nil)
      new(user: user, transaction: transaction, params: params, create_alias: create_alias, requested_alias: requested_alias).call
    end

    def initialize(user:, transaction:, params: {}, create_alias: false, requested_alias: nil)
      @user = user
      @transaction = transaction
      @params = params || {}
      @create_aliases = create_alias
      @requested_alias = requested_alias.presence
    end

    def call
      return failure("Imported transaction was not found.", :not_found) unless transaction.user_id == user.id

      confirmed_source = nil # : untyped
      failure_result = nil # : (Dry::Monads::Result::Failure | Dry::Monads::Result::Success)?

      transaction.transaction do
        transaction.source_document&.lock!
        begin
          transaction.lock!
          transaction.reload
        rescue ActiveRecord::RecordNotFound
          failure_result = failure("Imported transaction was not found.", :gone)
          raise ActiveRecord::Rollback
        end

        if transaction.confirmed?
          if transaction.confirmed_source.present?
            confirmed_source = transaction.confirmed_source
            next
          else
            failure_result = failure("Already confirmed but confirmed source record is missing", :confirmation_error)
            raise ActiveRecord::Rollback
          end
        end

        submitted_lock_version = params[:lock_version] || params["lock_version"]
        if submitted_lock_version.present? && transaction.lock_version.to_s != submitted_lock_version.to_s
          failure_result = failure("This transaction was updated in another session. Please reload to review the latest changes.", :conflict)
          raise ActiveRecord::Rollback
        end

        if params.present?
          transaction.assign_attributes(params)
          if transaction.matched_party_id.present? && transaction.matched_tenancy_id.present?
            transaction.status = "matched"
          end
        end

        unless transaction.valid?
          failure_result = failure(transaction.errors.full_messages.to_sentence, :validation_error)
          raise ActiveRecord::Rollback
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

        transaction.status = "confirmed"
        transaction.confirmed_source = created_source
        transaction.save!
        user.increment_inbox_revision!
        confirmed_source = created_source
      end

      return failure_result if failure_result

      Turbo::StreamsChannel.broadcast_remove_to(
        [ user, :inbox ],
        target: "imported_transaction_#{transaction.id}"
      )
      ImportedTransactions::InboxBroadcastService.call(user: user)

      success(confirmed_source)
    rescue ActiveRecord::StaleObjectError
      failure("This transaction was updated in another session. Please reload to review the latest changes.", :conflict)
    rescue ActiveRecord::RecordNotUnique
      failure("This transaction has already been recorded in another confirmed source.", :duplicate)
    rescue ActiveRecord::RecordNotFound => e
      failure(e.message.presence || "Required record was not found.", :not_found)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, :validation_error)
    end

    private

      attr_reader :user, :transaction, :params

      def confirm_receipt
        tenancy = user.tenancies.find_by(id: transaction.matched_tenancy_id)
        payer_party = user.parties.find_by(id: transaction.matched_party_id)

        result = Receipts::CreateService.call(
          tenancy: tenancy,
          payer_party: payer_party,
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
        tenancy = user.tenancies.find_by(id: transaction.matched_tenancy_id)
        deposit = tenancy&.security_deposit
        unless deposit
          return failure(
            "No security-deposit requirement exists for this tenancy. Set up the security deposit before confirming this import.",
            :missing_security_deposit
          )
        end

        payer_party = user.parties.find_by(id: transaction.matched_party_id)
        result = SecurityDepositTransactions::ReceiveService.call(
          security_deposit: deposit,
          party: payer_party,
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

      attr_reader :user, :transaction, :params, :requested_alias

      def create_party_aliases
        party = transaction.matched_party
        return unless party

        proposed = transaction.proposed_alias_for(party)
        return unless proposed

        if requested_alias.present? && requested_alias != proposed
          return
        end

        create_party_alias(proposed)
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
