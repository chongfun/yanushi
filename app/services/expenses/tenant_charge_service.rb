module Expenses
  class TenantChargeService
    def self.call(expense)
      new(expense).call
    end

    def initialize(expense)
      @expense = expense
    end

    def call
      if ActiveModel::Type::Boolean.new.cast(@expense.tenant_reimbursable)
        upsert_tenant_charge
      else
        @expense.tenant_charge&.destroy
      end
    end

    private
      def upsert_tenant_charge
        target_lease_id = @expense.reimburse_lease_id.presence || @expense.rental_property.leases.first&.id
        return unless target_lease_id

        charge = @expense.tenant_charge || @expense.build_tenant_charge
        charge.update!(
          lease_id: target_lease_id,
          amount: charge_amount(charge),
          charge_date: @expense.expense_date,
          description: "Reimbursement for #{@expense.category}: #{@expense.description}"
        )
      end

      def charge_amount(charge)
        old_expense_amount = @expense.amount_before_last_save
        previous_charge_amount = charge.amount_before_last_save || charge.amount

        if raw_reimburse_amount.nil?
          if old_expense_amount && (previous_charge_amount.nil? || previous_charge_amount == old_expense_amount)
            @expense.amount
          else
            previous_charge_amount || @expense.amount
          end
        elsif raw_reimburse_amount.to_s.strip.empty?
          @expense.amount
        else
          submitted_amount(previous_charge_amount, old_expense_amount)
        end
      end

      def submitted_amount(previous_charge_amount, old_expense_amount)
        submitted_amount = parsed_reimburse_amount
        return @expense.amount unless submitted_amount

        if charge_previously_matched_expense?(submitted_amount, previous_charge_amount, old_expense_amount)
          @expense.amount
        else
          submitted_amount
        end
      end

      def charge_previously_matched_expense?(submitted_amount, previous_charge_amount, old_expense_amount)
        old_expense_amount &&
          submitted_amount == old_expense_amount &&
          (previous_charge_amount.nil? || previous_charge_amount == old_expense_amount)
      end

      def parsed_reimburse_amount
        BigDecimal(raw_reimburse_amount.to_s)
      rescue ArgumentError
        nil
      end

      def raw_reimburse_amount
        @expense.raw_reimburse_amount
      end
  end
end
