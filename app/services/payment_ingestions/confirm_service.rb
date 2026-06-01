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
      return failure("Already confirmed", :already_confirmed) if ingestion.confirmed?
      return failure("Cannot confirm: missing required fields or duplicate exists", :not_confirmable) unless ingestion.confirmable?

      payment = nil
      ingestion.transaction do
        ingestion.lock!
        raise ConfirmationError, "Already confirmed" if ingestion.confirmed?
        raise ConfirmationError, "Cannot confirm: missing required fields or duplicate exists" unless ingestion.confirmable?

        payment = create_payment
        create_aliases if create_aliases?
        ingestion.update!(status: :confirmed, tenant_payment: payment)
      end

      success(payment)
    rescue ActiveRecord::RecordNotUnique
      failure("This transaction has already been recorded in another tenant payment.", :duplicate)
    rescue ConfirmationError => e
      failure(e.message, :confirmation_error)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, :validation_error)
    end

    private

    attr_reader :user, :ingestion

    def create_payment
      TenantPayment.create!(
        lease: ingestion.lease,
        amount: ingestion.amount,
        payment_date: ingestion.payment_date,
        payment_method: ingestion.payment_method,
        transaction_number: ingestion.transaction_number
      )
    end

    def create_aliases
      create_alias(ingestion.payer_name)
      create_alias(ingestion.payer_username)
    end

    def create_aliases?
      @create_aliases
    end

    def create_alias(alias_name)
      tenant = ingestion.tenant
      return unless tenant&.alias_candidate?(alias_name)

      tenant.tenant_aliases.create!(alias_name:)
    end

    def success(data)
      ServiceResult.success(data)
    end

    def failure(error, code)
      ServiceResult.failure(error:, code:)
    end
  end
end
