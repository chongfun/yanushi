module Expenses
  class AccountMap
    UnknownExpenseKindError = Class.new(StandardError)

    MAPPING = {
      "advertising" => "expense_advertising",
      "auto_and_travel" => "expense_auto_travel",
      "cleaning_and_maintenance" => "expense_cleaning_maintenance",
      "commissions" => "expense_commissions",
      "insurance" => "expense_insurance",
      "legal_and_professional" => "expense_legal_professional",
      "management" => "expense_management",
      "mortgage_interest" => "expense_mortgage_interest",
      "other_interest" => "expense_other_interest",
      "repairs" => "expense_repairs",
      "supplies" => "expense_supplies",
      "taxes" => "expense_taxes",
      "utilities" => "expense_utilities",
      "other" => "expense_other"
    }.freeze

    def self.account_key_for(expense_kind)
      key = expense_kind.to_s
      MAPPING.fetch(key) do
        raise UnknownExpenseKindError, "No accounting mapping defined for expense kind '#{expense_kind}'"
      end
    end

    def self.supported_kinds
      MAPPING.keys
    end
  end
end
