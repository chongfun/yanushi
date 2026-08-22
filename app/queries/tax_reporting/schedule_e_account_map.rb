module TaxReporting
  class ScheduleEAccountMap
    MAPPING = {
      "expense_advertising" => :advertising,
      "expense_auto_travel" => :auto_and_travel,
      "expense_cleaning_maintenance" => :cleaning_and_maintenance,
      "expense_commissions" => :commissions,
      "expense_insurance" => :insurance,
      "expense_legal_professional" => :legal_and_professional,
      "expense_management" => :management,
      "expense_mortgage_interest" => :mortgage_interest,
      "expense_other_interest" => :other_interest,
      "expense_repairs" => :repairs,
      "expense_supplies" => :supplies,
      "expense_taxes" => :taxes,
      "expense_utilities" => :utilities,
      "expense_other" => :other
    }.freeze

    def self.category_for(account_key)
      MAPPING[account_key.to_s]
    end

    def self.supported_keys
      MAPPING.keys
    end

    def self.supported_categories
      MAPPING.values.uniq
    end
  end
end
