module TaxReporting
  class ScheduleEQuery
    def self.call(property:, tax_year: nil)
      new(property: property, tax_year: tax_year).call
    end

    def initialize(property:, tax_year: nil)
      @property = property
      @tax_year = parse_year(tax_year)
    end

    def call
      return empty_result unless property

      tax_profile = property.tax_profile_for(tax_year)
      status = tax_profile ? :ok : :tax_profile_required

      period_postings = load_period_postings

      rents_received_cents, rents_drilldown = calculate_rents_received(period_postings)
      expenses_by_category, total_expenses_cents, other_details, expense_drilldown = calculate_expenses(period_postings)
      review_items = collect_review_items(period_postings)

      net_income_cents = rents_received_cents - total_expenses_cents

      ScheduleEResult.new(
        property: property,
        tax_year: tax_year,
        tax_profile: tax_profile,
        status: status,
        rents_received_cents: rents_received_cents,
        expenses_by_category_cents: expenses_by_category,
        total_expenses_cents: total_expenses_cents,
        net_income_cents: net_income_cents,
        other_expense_details: other_details,
        review_items: review_items,
        rents_received_drilldown: rents_drilldown,
        expense_drilldown_by_category: expense_drilldown
      )
    end

    private

      attr_reader :property, :tax_year

      def parse_year(year)
        y = year.to_i
        y.positive? ? y : Date.current.year
      end

      def start_date
        Date.new(tax_year, 1, 1)
      end

      def end_date
        Date.new(tax_year, 12, 31)
      end

      def load_period_postings
        prop = property
        return Posting.none unless prop

        prop.postings
            .joins(:journal_entry)
            .where(journal_entries: { occurred_on: start_date..end_date })
            .includes(:account, :party, :rentable_unit, :tenancy, journal_entry: [ :source, :reversal, :reversal_of ])
            .order("journal_entries.occurred_on ASC, journal_entries.id ASC, postings.id ASC")
      end

      def calculate_rents_received(postings)
        rents_cents = 0
        drilldown = [] # : Array[ScheduleEResult::IncomeDrilldownItem]

        cash_postings = postings.select { |p| p.account&.key == "cash" }

        cash_postings.each do |posting|
          entry = posting.journal_entry
          classification = ScheduleEEventMap.classify_income_event(entry)

          case classification
          when :rents_received
            rents_cents += posting.amount_cents.to_i
            drilldown << ScheduleEResult::IncomeDrilldownItem.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              label: "Payment received",
              description: entry.description,
              amount_cents: posting.amount_cents.to_i,
              party: posting.party,
              journal_entry: entry,
              reversal: false
            )
          when :rents_received_reversal
            rents_cents += posting.amount_cents.to_i # posting.amount_cents is negative for cash reversal
            drilldown << ScheduleEResult::IncomeDrilldownItem.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              label: "Payment reversal",
              description: entry.description,
              amount_cents: posting.amount_cents.to_i,
              party: posting.party,
              journal_entry: entry,
              reversal: true
            )
          end
        end

        [ rents_cents, drilldown ]
      end

      def calculate_expenses(postings)
        categories = {} # : Hash[Symbol, Integer]
        ScheduleEAccountMap.supported_categories.each { |cat| categories[cat] = 0 }
        other_details = [] # : Array[ScheduleEResult::OtherExpenseDetail]
        drilldown = Hash.new { |h, k| h[k] = [] }

        expense_postings = postings.select { |p| p.account&.account_type == "expense" }

        expense_postings.each do |posting|
          entry = posting.journal_entry
          category = ScheduleEAccountMap.category_for(posting.account&.key) || :other

          current_val = categories[category] || 0
          categories[category] = (current_val + posting.amount_cents.to_i).to_i

          is_reversal = entry.reversal? || entry.event_type == "reversal"
          item_desc = entry.source.respond_to?(:description) ? entry.source.description.presence : nil
          item_desc ||= entry.description

          drilldown[category] << ScheduleEResult::ExpenseDrilldownItem.new(
            id: entry.id,
            occurred_on: entry.occurred_on,
            category: category,
            description: item_desc,
            amount_cents: posting.amount_cents.to_i,
            property: posting.property,
            rentable_unit: posting.rentable_unit,
            journal_entry: entry,
            reversal: is_reversal
          )

          if category == :other && posting.amount_cents.to_i != 0
            other_details << ScheduleEResult::OtherExpenseDetail.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              description: item_desc,
              amount_cents: posting.amount_cents.to_i,
              journal_entry: entry
            )
          end
        end

        total_cents = categories.values.sum

        [ categories, total_cents, other_details, drilldown ]
      end

      def collect_review_items(postings)
        items = [] # : Array[ScheduleEResult::TaxReviewItem]
        seen_entry_ids = Set.new

        postings.each do |posting|
          entry = posting.journal_entry
          next if seen_entry_ids.include?(entry.id)

          seen_entry_ids << entry.id

          if entry.event_type == "deposit_applied"
            items << ScheduleEResult::TaxReviewItem.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              amount_cents: posting.amount_cents.to_i.abs,
              reason: "Security deposit applied to charge; review tax treatment",
              source: entry.source,
              journal_entry: entry
            )
          end
        end

        items
      end

      def empty_result
        ScheduleEResult.new(
          property: property,
          tax_year: tax_year,
          tax_profile: nil,
          status: :tax_profile_required,
          rents_received_cents: 0,
          expenses_by_category_cents: {},
          total_expenses_cents: 0,
          net_income_cents: 0,
          other_expense_details: [],
          review_items: [],
          rents_received_drilldown: [],
          expense_drilldown_by_category: {}
        )
      end
  end
end
