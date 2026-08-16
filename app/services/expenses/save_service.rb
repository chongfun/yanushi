module Expenses
  class SaveService
    def self.call(expense:)
      new(expense: expense).call
    end

    def initialize(expense:)
      @expense = expense
    end

    def call
      is_new = !expense.persisted?

      Expense.transaction do
        Expense.lock.find(expense.id) if expense.persisted?

        expense.save!

        if is_new && expense.tenant_reimbursable && expense.reimburse_tenancy_id.present?
          tenancy = Tenancy.find_by(id: expense.reimburse_tenancy_id)
          if tenancy
            reimburse_amt = expense.reimburse_amount.presence || expense.amount
            result = Charges::CreateReimbursementService.call(
              expense: expense,
              tenancy: tenancy,
              amount: reimburse_amt,
              charge_date: expense.expense_date,
              due_on: expense.expense_date,
              description: expense.description
            )
            unless result.success?
              expense.errors.add(:base, result.failure.error)
              raise ActiveRecord::RecordInvalid, expense
            end
            expense.association(:reimbursement_charges).reset
          end
        end
      end
      ServiceResult.success(expense)
    rescue ActiveRecord::RecordInvalid => e
      ServiceResult.failure(data: expense, error: e.record.errors.full_messages.to_sentence, code: :validation_error)
    end

    private

      attr_reader :expense
  end
end
