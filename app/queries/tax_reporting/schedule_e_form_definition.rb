module TaxReporting
  class ScheduleEFormDefinition
    LineDefinition = Data.define(:line_number, :category, :label, :type)

    EXPENSE_LINES = [
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

    INCOME_LINES_2012_PRESENT = [
      LineDefinition.new(line_number: 3, category: :rents_received, label: "Rents received", type: :income)
    ].freeze

    INCOME_LINES_2011 = [
      LineDefinition.new(line_number: 3, category: :rents_received, label: "Rents received (Line 3a)", type: :income)
    ].freeze

    attr_reader :tax_year

    def self.for(tax_year)
      new(tax_year)
    end

    def initialize(tax_year)
      @tax_year_obj = TaxYear.parse(tax_year, default: Date.current.year) || TaxYear.new(Date.current.year)
      @tax_year = @tax_year_obj.to_i
    end

    def income_lines
      if @tax_year == 2011
        INCOME_LINES_2011
      else
        INCOME_LINES_2012_PRESENT
      end
    end

    def expense_lines
      EXPENSE_LINES
    end

    def all_lines
      income_lines + expense_lines
    end

    def line_for(category)
      all_lines.find { |l| l.category == category.to_sym }
    end

    def reference_notice
      if @tax_year > 2025
        "Layout reflects the 2025 IRS Schedule E reference form until the official #{@tax_year} form is published."
      elsif @tax_year == 2011
        "Layout reflects the 2011 IRS Schedule E form revision (Line 3a rents layout)."
      elsif @tax_year < 2011
        "Layout reflects the 2011 IRS Schedule E reference form."
      end
    end
  end
end
