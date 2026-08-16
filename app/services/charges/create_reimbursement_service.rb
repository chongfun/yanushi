module Charges
  class CreateReimbursementService
    def self.call(expense:, tenancy:, amount_cents: nil, amount: nil, charge_date: nil, due_on: nil, description: nil)
      new(
        expense: expense,
        tenancy: tenancy,
        amount_cents: amount_cents,
        amount: amount,
        charge_date: charge_date,
        due_on: due_on,
        description: description
      ).call
    end

    def initialize(expense:, tenancy:, amount_cents: nil, amount: nil, charge_date: nil, due_on: nil, description: nil)
      @expense = expense
      @tenancy = tenancy
      @amount_cents = amount_cents
      @amount = amount
      @charge_date = charge_date || Date.current
      @due_on = due_on || @charge_date
      @description = description
    end

    def call
      unless expense && tenancy
        return ServiceResult.failure(error: "Expense and Tenancy are required", code: :invalid_input)
      end

      if expense.property_id != tenancy.property&.id
        return ServiceResult.failure(
          error: "Expense property does not match tenancy property",
          code: :property_mismatch
        )
      end

      if expense.accounting_user != tenancy.accounting_user
        return ServiceResult.failure(
          error: "Expense owner does not match tenancy owner",
          code: :ownership_mismatch
        )
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

      Expense.transaction do
        expense.lock!

        expense_cents = expense.amount ? (BigDecimal(expense.amount.to_s) * 100).round : 0
        already_reimbursed_cents = expense.reimbursement_charges.active.sum(:amount_cents)
        remaining_cents = expense_cents - already_reimbursed_cents

        if resolved_cents > remaining_cents
          remaining_dollars = sprintf("%.2f", remaining_cents / 100.0)
          return ServiceResult.failure(
            error: "Reimbursement amount exceeds remaining reimbursable amount for this expense ($#{remaining_dollars})",
            code: :exceeds_expense_amount
          )
        end

        Charges::CreateService.call(
          tenancy: tenancy,
          charge_kind: "reimbursement",
          source_expense: expense,
          amount_cents: resolved_cents,
          charge_date: charge_date,
          due_on: due_on,
          description: description
        )
      end
    end

    private

      attr_reader :expense, :tenancy, :amount_cents, :amount, :charge_date, :due_on, :description
  end
end
