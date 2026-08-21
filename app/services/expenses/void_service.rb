module Expenses
  class VoidService
    def self.call(expense:, user: nil)
      new(expense: expense, user: user).call
    end

    def initialize(expense:, user: nil)
      @expense = expense
      @user = user
    end

    def call
      return failure("Expense is required", :invalid_input) unless expense

      if user && expense.accounting_user != user
        return failure("Expense was not found", :not_found)
      end

      expense.with_lock do
        if expense.voided?
          return success(expense)
        end

        if expense.reimbursement_charges.active.exists?
          return failure(
            "Cannot void expense with active reimbursement charges. Void all reimbursement charges first.",
            :active_reimbursements
          )
        end

        entry = expense.journal_entries.find_by(event_type: "expense_posted")
        if entry
          reversal_result = Accounting::ReverseEntryService.call(
            journal_entry: entry,
            occurred_on: expense.paid_on
          )

          unless reversal_result.success?
            return reversal_result
          end
        end

        expense.update_columns(voided_at: Time.current)
        success(expense)
      end
    end

    private

      attr_reader :expense, :user

      def success(data)
        ServiceResult.success(data)
      end

      def failure(error, code)
        ServiceResult.failure(error: error, code: code)
      end
  end
end
