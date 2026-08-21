module Expenses
  class PostService
    def self.call(expense:)
      new(expense:).call
    end

    def initialize(expense:)
      @expense = expense
    end

    def call
      return ServiceResult.failure(error: "Expense is required", code: :invalid_input) unless expense
      return ServiceResult.failure(error: "Expense must have an owner", code: :invalid_input) unless expense.accounting_user

      account_key = Expenses::AccountMap.account_key_for(expense.expense_kind)

      postings = [
        Accounting::PostingSpec.new(
          account_key: account_key,
          amount_cents: expense.amount_cents,
          property: expense.property,
          rentable_unit: expense.rentable_unit
        ),
        Accounting::PostingSpec.new(
          account_key: "cash",
          amount_cents: -expense.amount_cents,
          property: expense.property,
          rentable_unit: expense.rentable_unit
        )
      ]

      description = "#{expense.expense_kind.titleize} expense"

      Accounting::PostEntryService.call(
        user: expense.accounting_user,
        source: expense,
        event_type: "expense_posted",
        occurred_on: expense.paid_on,
        description: description,
        postings: postings
      )
    rescue Expenses::AccountMap::UnknownExpenseKindError => e
      ServiceResult.failure(error: e.message, code: :invalid_expense_kind)
    end

    private

      attr_reader :expense
  end
end
