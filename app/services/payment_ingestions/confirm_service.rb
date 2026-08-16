module PaymentIngestions
  class ConfirmService
    def self.call(user:, ingestion:, create_alias: false)
      new(user:, ingestion:, create_alias:).call
    end

    def initialize(user:, ingestion:, create_alias: false)
      @user = user
      @ingestion = ingestion
      @create_aliases = create_alias
    end

    def call
      return failure("Payment ingestion was not found.", :not_found) unless ingestion.user_id == user.id

      if ingestion.confirmed?
        if ingestion.receipt.present?
          return success(ingestion.receipt)
        else
          return failure("Already confirmed but receipt record is missing", :confirmation_error)
        end
      end

      return failure("Cannot confirm: missing required fields or duplicate exists", :not_confirmable) unless ingestion.confirmable?

      receipt = nil # : Receipt?
      ingestion.transaction do
        ingestion.payment_document&.lock!
        ingestion.lock!

        if ingestion.confirmed?
          if ingestion.receipt.present?
            receipt = ingestion.receipt
            next
          else
            raise ConfirmationError, "Already confirmed but receipt record is missing"
          end
        end

        raise ConfirmationError, "Cannot confirm: missing required fields or duplicate exists" unless ingestion.confirmable?

        created = create_receipt
        create_aliases if create_aliases?
        ingestion.update!(status: :confirmed, receipt: created)
        receipt = created
      end

      if receipt
        success(receipt)
      else
        failure("Failed to create receipt", :confirmation_error)
      end
    rescue ActiveRecord::RecordNotUnique
      failure("This transaction has already been recorded in another payment receipt.", :duplicate)
    rescue ActiveRecord::RecordNotFound
      failure("Payment ingestion was not found.", :not_found)
    rescue ConfirmationError => e
      failure(e.message, :confirmation_error)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, :validation_error)
    end

    private

      attr_reader :user, :ingestion

      def create_receipt
        tenancy = ingestion.tenancy
        raise ConfirmationError, "Missing tenancy" unless tenancy

        party = ingestion.party
        raise ConfirmationError, "Missing payer party" unless party

        result = Receipts::CreateService.call(
          tenancy: tenancy,
          payer_party: party,
          amount: ingestion.amount,
          received_on: ingestion.payment_date,
          payment_method: ingestion.payment_method,
          external_reference: ingestion.transaction_number
        )
        if result.success?
          result.value!.data[:receipt]
        else
          raise ConfirmationError, result.failure.error
        end
      end

      def create_aliases
        create_alias(ingestion.payer_name)
        create_alias(ingestion.payer_username)
      end

      def create_aliases?
        @create_aliases
      end

      def create_alias(alias_name)
        party = ingestion.party
        return unless party&.alias_candidate?(alias_name)

        party.party_aliases.create!(alias_name: alias_name)
      end

      def success(data)
        ServiceResult.success(data)
      end

      def failure(error, code)
        ServiceResult.failure(error: error, code: code)
      end
  end
end
