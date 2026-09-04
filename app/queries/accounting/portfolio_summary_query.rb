module Accounting
  # Period totals for a user's whole portfolio (optionally narrowed to one
  # property), shaped like PropertySummaryQuery's income/expense/net figures so
  # the same summary strip renders for Money Activity and property Activity.
  #
  # Totals come from one grouped aggregate: the page of rows is fetched
  # separately by PortfolioActivityQuery, so no postings are loaded here.
  class PortfolioSummaryQuery
    PortfolioSummaryResult = Data.define(
      :date_range,
      :property_id,
      :net_cash_movement_cents,
      :income_recognized_cents,
      :operating_expenses_cents,
      :interest_expenses_cents,
      :total_expenses_cents,
      :net_income_cents
    )

    def self.call(user:, date_range: nil, from: nil, through: nil, year: nil, property_id: nil)
      new(
        user: user,
        date_range: date_range,
        from: from,
        through: through,
        year: year,
        property_id: property_id
      ).call
    end

    def initialize(user:, date_range: nil, from: nil, through: nil, year: nil, property_id: nil)
      @user = user
      @date_range = date_range || DateRange.parse(from: from, through: through, year: year)
      @property_id = property_id.presence
    end

    def call
      return empty_result unless user && date_range.valid?

      net_cash_movement_cents = 0
      income_recognized_cents = 0
      operating_expenses_cents = 0
      interest_expenses_cents = 0

      grouped_amounts.each do |group, amount|
        account_type, account_key = group
        amount_cents = amount.to_i

        case account_type
        when "asset"
          net_cash_movement_cents += amount_cents if account_key == "cash"
        when "expense"
          if PropertySummaryQuery::NON_OPERATING_EXPENSE_KEYS.include?(account_key)
            interest_expenses_cents += amount_cents
          else
            operating_expenses_cents += amount_cents
          end
        when "income"
          # Income is credited, so raw posting amounts are negative.
          income_recognized_cents += -amount_cents
        end
      end

      total_expenses_cents = operating_expenses_cents + interest_expenses_cents

      PortfolioSummaryResult.new(
        date_range: date_range,
        property_id: property_id,
        net_cash_movement_cents: net_cash_movement_cents,
        income_recognized_cents: income_recognized_cents,
        operating_expenses_cents: operating_expenses_cents,
        interest_expenses_cents: interest_expenses_cents,
        total_expenses_cents: total_expenses_cents,
        net_income_cents: income_recognized_cents - total_expenses_cents
      )
    end

    private

      attr_reader :user, :date_range, :property_id

      def grouped_amounts
        scope = Posting.joins(:account, :journal_entry).where(property_id: property_scope.select(:id))

        scope = if date_range.from
          scope.where("journal_entries.occurred_on BETWEEN ? AND ?", date_range.from, date_range.through)
        else
          scope.where("journal_entries.occurred_on <= ?", date_range.through)
        end

        scope.group("accounts.account_type", "accounts.key").sum(:amount_cents)
      end

      def property_scope
        scope = user.properties
        property_id ? scope.where(id: property_id) : scope
      end

      def empty_result
        PortfolioSummaryResult.new(
          date_range: date_range,
          property_id: property_id,
          net_cash_movement_cents: 0,
          income_recognized_cents: 0,
          operating_expenses_cents: 0,
          interest_expenses_cents: 0,
          total_expenses_cents: 0,
          net_income_cents: 0
        )
      end
  end
end
