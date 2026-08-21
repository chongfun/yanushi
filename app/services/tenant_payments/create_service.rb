module TenantPayments
  class CreateService
    def self.call(tenancy: nil, amount: nil, amount_cents: nil, payment_date: nil, payment_method: "other", transaction_number: nil, description: nil, params: nil)
      p = (params || {}).to_h.symbolize_keys
      t = tenancy || (p[:tenancy_id].present? ? Tenancy.find_by(id: p[:tenancy_id]) : nil)
      amt = amount || p[:amount]
      cents = amount_cents || p[:amount_cents]
      date = payment_date || p[:payment_date] || Date.current
      method = p[:payment_method].presence || payment_method || "other"
      txn_num = p[:transaction_number] || transaction_number
      desc = description || p[:description]

      new(
        tenancy: t,
        amount: amt,
        amount_cents: cents,
        payment_date: date,
        payment_method: method,
        transaction_number: txn_num,
        description: desc
      ).call
    end

    def initialize(tenancy:, amount: nil, amount_cents: nil, payment_date: nil, payment_method: "other", transaction_number: nil, description: nil)
      @tenancy = tenancy
      @amount = amount
      @amount_cents = amount_cents
      @payment_date = payment_date || Date.current
      @payment_method = payment_method
      @transaction_number = transaction_number
      @description = description
    end

    def call
      unless tenancy
        return ServiceResult.failure(error: "Tenancy is required", code: :invalid_input)
      end

      resolved_cents = if amount_cents.present?
        amount_cents.to_i
      elsif amount.present?
        begin
          (BigDecimal(amount.to_s) * 100).round
        rescue StandardError
          0
        end
      else
        0
      end

      resolved_dollars = BigDecimal(resolved_cents) / 100

      created_payment = nil # : TenantPayment?
      created_entry = nil # : JournalEntry?
      failure_result = nil # : Dry::Monads::Result::Failure?

      TenantPayment.transaction do
        payment = TenantPayment.new(
          tenancy: tenancy,
          amount: resolved_dollars,
          payment_date: payment_date,
          payment_method: payment_method,
          transaction_number: transaction_number
        )

        unless payment.save
          failure_result = ServiceResult.failure(
            data: { tenant_payment: payment },
            error: payment.errors.full_messages.to_sentence,
            code: :validation_error
          )
          raise ActiveRecord::Rollback
        end

        postings = [
          Accounting::PostingSpec.new(
            account_key: "cash",
            amount_cents: resolved_cents,
            tenancy: tenancy
          ),
          Accounting::PostingSpec.new(
            account_key: "tenant_receivable",
            amount_cents: -resolved_cents,
            tenancy: tenancy
          )
        ]

        desc = description.presence || "Payment received - #{payment_method.to_s.humanize}"

        post_result = Accounting::PostEntryService.call(
          source: payment,
          event_type: "payment_received",
          occurred_on: payment.payment_date,
          postings: postings,
          description: desc
        )

        unless post_result.success?
          failure_result = ServiceResult.failure(
            data: { tenant_payment: payment },
            error: post_result.failure.error,
            code: post_result.failure.code
          )
          raise ActiveRecord::Rollback
        end

        created_payment = payment
        created_entry = post_result.value!.data[:journal_entry]
      end

      if (f = failure_result)
        f
      elsif created_payment && created_entry
        ServiceResult.success(tenant_payment: created_payment, journal_entry: created_entry)
      else
        ServiceResult.failure(error: "Failed to create and post tenant payment", code: :creation_failed)
      end
    end

    private

      attr_reader :tenancy, :amount, :amount_cents, :payment_date,
                  :payment_method, :transaction_number, :description
  end
end
