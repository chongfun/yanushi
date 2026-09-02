module Dashboards
  class PortfolioSummaryQuery
    class PortfolioSummary < Data.define(
      :properties_count,
      :occupied_units_count,
      :total_units_count,
      :vacant_units_count,
      :outstanding_balances_cents,
      :net_income_cents,
      :income_cents,
      :expenses_cents
    )
      def outstanding_balances
        BigDecimal(outstanding_balances_cents.to_s) / 100
      end

      def net_income
        BigDecimal(net_income_cents.to_s) / 100
      end

      def income
        BigDecimal(income_cents.to_s) / 100
      end

      def expenses
        BigDecimal(expenses_cents.to_s) / 100
      end
    end

    def self.call(user:, date_range: nil, properties: nil, tenancies: nil, balances: nil)
      new(user: user, date_range: date_range, properties: properties, tenancies: tenancies, balances: balances).call
    end

    def initialize(user:, date_range: nil, properties: nil, tenancies: nil, balances: nil)
      @user = user
      @date_range = date_range || default_date_range
      @properties = properties
      @tenancies = tenancies
      @balances = balances
    end

    def call
      u = user
      return empty_summary unless u

      as_of_date = date_range.through || Date.current

      properties_count = if properties
        properties.size
      else
        u.properties.count
      end

      total_units_count = if properties
        properties.flat_map(&:rentable_units).count(&:active?)
      else
        RentableUnit.joins(:property).where(properties: { user_id: u.id }, active: true).count
      end

      occupied_units_count = if properties
        active_units = properties.flat_map(&:rentable_units).select(&:active?)
        active_units.count { |unit| unit.tenancies.any? { |t| t.active?(as_of_date) } }
      else
        active_tenancies = Tenancy.joins(rentable_unit: :property)
                                  .where(properties: { user_id: u.id }, rentable_units: { active: true })
                                  .active(as_of_date)
        active_tenancies.distinct.count(:rentable_unit_id)
      end

      vacant_units_count = [ total_units_count - occupied_units_count, 0 ].max

      outstanding_balances_cents = if balances && as_of_date == Date.current
        balances.values.select(&:positive?).sum
      else
        all_user_tenancies = tenancies || Tenancy.joins(rentable_unit: :property).where(properties: { user_id: u.id })
        b = Accounting::TenancyBalancesQuery.call(tenancies: all_user_tenancies, as_of: as_of_date)
        b.values.select(&:positive?).sum
      end

      financials = compute_financials

      PortfolioSummary.new(
        properties_count: properties_count,
        occupied_units_count: occupied_units_count,
        total_units_count: total_units_count,
        vacant_units_count: vacant_units_count,
        outstanding_balances_cents: outstanding_balances_cents,
        net_income_cents: financials[:net_income_cents],
        income_cents: financials[:income_cents],
        expenses_cents: financials[:expenses_cents]
      )
    end

    private

      attr_reader :user, :date_range, :properties, :tenancies, :balances

      def default_date_range
        Accounting::DateRange.new(
          from: Date.current.beginning_of_year,
          through: Date.current
        )
      end

      def compute_financials
        period_scope = Posting.joins(:account, :journal_entry)
                              .where(journal_entries: { user_id: user.id })

        if date_range.from
          period_scope = period_scope.where("journal_entries.occurred_on BETWEEN ? AND ?", date_range.from, date_range.through)
        else
          period_scope = period_scope.where("journal_entries.occurred_on <= ?", date_range.through)
        end

        income_cents = 0
        expenses_cents = 0

        period_scope.where(accounts: { account_type: %w[income expense] })
                    .group("accounts.account_type")
                    .sum(:amount_cents)
                    .each do |account_type, raw_cents|
                      case account_type
                      when "income"
                        income_cents = -raw_cents
                      when "expense"
                        expenses_cents = raw_cents
                      end
                    end

        net_income_cents = income_cents - expenses_cents

        {
          income_cents: income_cents,
          expenses_cents: expenses_cents,
          net_income_cents: net_income_cents
        }
      end

      def empty_summary
        PortfolioSummary.new(
          properties_count: 0,
          occupied_units_count: 0,
          total_units_count: 0,
          vacant_units_count: 0,
          outstanding_balances_cents: 0,
          net_income_cents: 0,
          income_cents: 0,
          expenses_cents: 0
        )
      end
  end
end
