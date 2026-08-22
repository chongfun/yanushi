module TaxReporting
  class ScheduleEFormDefinition
    LineDefinition = Data.define(:line_number, :category, :label, :type)

    EXPENSE_LINES_2025 = [
      LineDefinition.new(line_number: 5, category: :advertising, label: "Advertising", type: :expense),
      LineDefinition.new(line_number: 6, category: :auto_and_travel, label: "Auto and travel", type: :expense),
      LineDefinition.new(line_number: 7, category: :cleaning_and_maintenance, label: "Cleaning and maintenance", type: :expense),
      LineDefinition.new(line_number: 8, category: :commissions, label: "Commissions", type: :expense),
      LineDefinition.new(line_number: 9, category: :insurance, label: "Insurance", type: :expense),
      LineDefinition.new(line_number: 10, category: :legal_and_professional, label: "Legal and other professional fees", type: :expense),
      LineDefinition.new(line_number: 11, category: :management, label: "Management fees", type: :expense),
      LineDefinition.new(line_number: 12, category: :mortgage_interest, label: "Mortgage interest paid to banks, etc.", type: :expense),
      LineDefinition.new(line_number: 13, category: :other_interest, label: "Other interest", type: :expense),
      LineDefinition.new(line_number: 14, category: :repairs, label: "Repairs", type: :expense),
      LineDefinition.new(line_number: 15, category: :supplies, label: "Supplies", type: :expense),
      LineDefinition.new(line_number: 16, category: :taxes, label: "Taxes", type: :expense),
      LineDefinition.new(line_number: 17, category: :utilities, label: "Utilities", type: :expense),
      LineDefinition.new(line_number: 19, category: :other, label: "Other", type: :expense)
    ].freeze

    INCOME_LINES_2025 = [
      LineDefinition.new(line_number: 3, category: :rents_received, label: "Rents received", type: :income)
    ].freeze

    attr_reader :tax_year

    def self.for(tax_year)
      new(tax_year)
    end

    def initialize(tax_year)
      @tax_year = tax_year.to_i
    end

    def income_lines
      INCOME_LINES_2025
    end

    def expense_lines
      EXPENSE_LINES_2025
    end

    def all_lines
      income_lines + expense_lines
    end

    def line_for(category)
      all_lines.find { |l| l.category == category.to_sym }
    end
  end
end
