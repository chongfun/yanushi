module Expenses
  class SaveService
    def self.call(expense:)
      new(expense:).call
    end

    def initialize(expense:)
      @expense = expense
    end

    def call
      Expense.transaction do
        expense.save!
        Expenses::TenantChargeService.call(expense)
      end
      ServiceResult.success(expense)
    rescue ActiveRecord::RecordInvalid
      ServiceResult.failure(data: expense, error: expense.errors.full_messages.to_sentence, code: :validation_error)
    end

    private

    attr_reader :expense
  end
end
