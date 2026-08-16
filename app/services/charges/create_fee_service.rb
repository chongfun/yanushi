module Charges
  class CreateFeeService
    ALLOWED_KINDS = %w[late_fee other].freeze

    def self.call(tenancy:, amount_cents: nil, amount: nil, charge_kind: "late_fee", kind: nil, charge_date: nil, due_on: nil, description: nil)
      new(
        tenancy: tenancy,
        amount_cents: amount_cents,
        amount: amount,
        charge_kind: kind || charge_kind,
        charge_date: charge_date,
        due_on: due_on,
        description: description
      ).call
    end

    def initialize(tenancy:, amount_cents: nil, amount: nil, charge_kind: "late_fee", charge_date: nil, due_on: nil, description: nil)
      @tenancy = tenancy
      @amount_cents = amount_cents
      @amount = amount
      @charge_kind = charge_kind.to_s
      @charge_date = charge_date || Date.current
      @due_on = due_on || @charge_date
      @description = description
    end

    def call
      unless ALLOWED_KINDS.include?(charge_kind)
        return ServiceResult.failure(
          error: "Invalid fee kind: #{charge_kind}. Must be late_fee or other.",
          code: :invalid_input
        )
      end

      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: charge_kind,
        amount_cents: amount_cents,
        amount: amount,
        charge_date: charge_date,
        due_on: due_on,
        description: description
      )
    end

    private

      attr_reader :tenancy, :amount_cents, :amount, :charge_kind, :charge_date, :due_on, :description
  end
end
