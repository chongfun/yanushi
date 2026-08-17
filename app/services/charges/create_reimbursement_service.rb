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

      resolved_cents = parse_cents
      if resolved_cents.nil? || resolved_cents <= 0
        return ServiceResult.failure(
          error: "Reimbursement amount must be greater than zero",
          code: :invalid_amount
        )
      end

      expense.with_lock do
        unless expense.posted? && expense.active?
          return ServiceResult.failure(
            error: "Cannot create reimbursement for an unposted, voided, or superseded expense",
            code: :invalid_expense_state
          )
        end

        if expense.rentable_unit_id.present? && expense.rentable_unit_id != tenancy.rentable_unit_id
          return ServiceResult.failure(
            error: "Unit-scoped expense can only be reimbursed by tenancies in the same unit",
            code: :unit_mismatch
          )
        end

        already_reimbursed_cents = expense.reimbursement_charges.active.sum(:amount_cents)
        remaining_cents = expense.amount_cents.to_i - already_reimbursed_cents

        if resolved_cents > remaining_cents
          remaining_dollars = sprintf("%.2f", [ remaining_cents, 0 ].max / 100.0)
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

      def parse_cents
        if amount_cents.present?
          return nil unless amount_cents.is_a?(Integer)
          return nil if amount_cents <= 0

          amount_cents
        elsif amount.present?
          amt_str = amount.is_a?(Numeric) ? amount.to_s : amount.to_s.strip
          return nil unless amt_str.match?(/\A\d+(\.\d{1,2})?\z/)
          begin
            dec = BigDecimal(amt_str)
            return nil if dec <= 0

            (dec * 100).round
          rescue ArgumentError
            nil
          end
        else
          nil
        end
      end
  end
end
