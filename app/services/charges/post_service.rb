module Charges
  class PostService
    INCOME_ACCOUNTS = {
      "rent" => "rental_income",
      "late_fee" => "late_fee_income",
      "reimbursement" => "reimbursement_income",
      "other" => "other_tenant_income"
    }.freeze

    def self.call(charge:)
      new(charge: charge).call
    end

    def initialize(charge:)
      @charge = charge
    end

    def call
      unless charge.is_a?(Charge) && charge.persisted? && !charge.destroyed?
        return ServiceResult.failure(error: "Charge must be a persisted Charge record", code: :invalid_source)
      end

      if charge.voided?
        return ServiceResult.failure(error: "Cannot post a voided charge", code: :invalid_state)
      end

      income_account_key = INCOME_ACCOUNTS[charge.charge_kind]
      unless income_account_key
        return ServiceResult.failure(error: "Unknown charge kind: #{charge.charge_kind}", code: :invalid_input)
      end

      postings = [
        Accounting::PostingSpec.new(
          account_key: "tenant_receivable",
          amount_cents: charge.amount_cents,
          tenancy: charge.tenancy
        ),
        Accounting::PostingSpec.new(
          account_key: income_account_key,
          amount_cents: -charge.amount_cents,
          tenancy: charge.tenancy
        )
      ]

      description = default_description

      Accounting::PostEntryService.call(
        source: charge,
        event_type: "charge_posted",
        occurred_on: charge.charge_date,
        postings: postings,
        description: description
      )
    end

    private

      attr_reader :charge

      def default_description
        desc = charge.description
        return desc if desc.present?

        if charge.rent?
          start_date = charge.service_period_start
          start_date ? "Rent - #{start_date.strftime('%B %Y')}" : "Rent"
        elsif charge.late_fee?
          "Late fee"
        elsif charge.reimbursement?
          "Utility reimbursement"
        else
          "Tenant charge"
        end
      end
  end
end
