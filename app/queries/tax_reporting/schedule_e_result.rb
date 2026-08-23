module TaxReporting
  class ScheduleEResult
    OtherExpenseDetail = Data.define(:id, :occurred_on, :description, :amount_cents, :journal_entry)
    class TaxReviewItem < Data.define(:id, :occurred_on, :amount_cents, :reason, :source, :journal_entry, :resolution, :review_kind)
      def self.new(id:, occurred_on:, amount_cents:, reason:, source:, journal_entry:, resolution: nil, review_kind: :income)
        super(
          id: id,
          occurred_on: occurred_on,
          amount_cents: amount_cents,
          reason: reason,
          source: source,
          journal_entry: journal_entry,
          resolution: resolution,
          review_kind: review_kind
        )
      end
      def resolved?
        resolution.present?
      end

      def unresolved?
        resolution.blank?
      end

      def treatment
        resolution&.treatment
      end

      def income?
        review_kind == :income
      end

      def expense?
        review_kind == :expense
      end

      def resolution_target
        (journal_entry&.reversal? && journal_entry.reversal_of.present?) ? journal_entry.reversal_of : journal_entry
      end

      def cross_year_reversal?
        target = resolution_target
        return false unless target && journal_entry&.reversal?

        target.occurred_on.year != occurred_on.year
      end

      def can_map_to_expense?
        target = resolution_target
        return false unless target

        target.postings.any? { |p| p.account&.account_type == "expense" }
      end

      def can_include_in_rents?
        target = resolution_target
        return false unless target

        is_deposit = target.event_type == "deposit_applied"
        has_cash_inflow = target.postings.any? do |p|
          p.account&.key == "cash" && p.amount_cents.to_i.positive?
        end
        is_expense_module_event = target.event_type == "expense_posted" || target.source_type == "Expense"
        is_pure_expense = target.postings.all? { |p| p.account&.account_type == "expense" || p.account&.account_type == "liability" }

        !is_expense_module_event && !is_pure_expense && (is_deposit || has_cash_inflow)
      end
    end
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

    def unresolved_review_items
      review_items.reject(&:resolved?)
    end

    def resolved_review_items
      review_items.select(&:resolved?)
    end

    def has_unresolved_reviews?
      unresolved_review_items.any?
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
