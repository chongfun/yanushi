module TaxReporting
  class ScheduleEResult
    OtherExpenseDetail = Data.define(:id, :occurred_on, :description, :amount_cents, :journal_entry)
    TaxReviewItem = Data.define(:id, :occurred_on, :amount_cents, :reason, :source, :journal_entry)
    IncomeDrilldownItem = Data.define(:id, :occurred_on, :label, :description, :amount_cents, :party, :journal_entry, :reversal)
    ExpenseDrilldownItem = Data.define(:id, :occurred_on, :category, :description, :amount_cents, :property, :rentable_unit, :journal_entry, :reversal)

    attr_reader :property,
                :tax_year,
                :tax_profile,
                :status,
                :rents_received_cents,
                :expenses_by_category_cents,
                :total_expenses_cents,
                :net_income_cents,
                :other_expense_details,
                :review_items,
                :rents_received_drilldown,
                :expense_drilldown_by_category

    def initialize(
      property:,
      tax_year:,
      tax_profile:,
      status:,
      rents_received_cents:,
      expenses_by_category_cents:,
      total_expenses_cents:,
      net_income_cents:,
      other_expense_details: [],
      review_items: [],
      rents_received_drilldown: [],
      expense_drilldown_by_category: {}
    )
      @property = property
      @tax_year = tax_year.to_i
      @tax_profile = tax_profile
      @status = status
      @rents_received_cents = rents_received_cents.to_i
      @expenses_by_category_cents = expenses_by_category_cents || {}
      @total_expenses_cents = total_expenses_cents.to_i
      @net_income_cents = net_income_cents.to_i
      @other_expense_details = other_expense_details
      @review_items = review_items
      @rents_received_drilldown = rents_received_drilldown
      @expense_drilldown_by_category = expense_drilldown_by_category
    end

    def tax_profile_configured?
      status == :ok && tax_profile.present?
    end

    def cents_for(category)
      expenses_by_category_cents[category.to_sym].to_i
    end

    def expense_for(category)
      BigDecimal(cents_for(category)) / 100
    end

    def rents_received
      BigDecimal(rents_received_cents) / 100
    end
    alias_method :total_income, :rents_received

    def total_expenses
      BigDecimal(total_expenses_cents) / 100
    end

    def net_income
      BigDecimal(net_income_cents) / 100
    end
  end
end
