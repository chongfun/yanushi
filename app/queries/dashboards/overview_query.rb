module Dashboards
  class OverviewQuery
    class PropertyRow < Data.define(
      :property,
      :occupied_units_count,
      :total_units_count,
      :balance_cents
    )
      def balance
        BigDecimal(balance_cents.to_s) / 100
      end
    end

    class OverviewResult < Data.define(
      :attention_items,
      :portfolio_summary,
      :properties,
      :recent_activity
    )
    end

    def self.call(user:)
      new(user: user).call
    end

    def initialize(user:)
      @user = user
    end

    def call
      u = user
      return empty_result unless u

      props = u.properties.order(:address).includes(
        rentable_units: { tenancies: [ { tenancy_parties: :party }, :rent_terms ] }
      ).to_a
      all_tenancies = props.flat_map { |p| p.rentable_units.flat_map(&:tenancies) }
      balances = Accounting::TenancyBalancesQuery.call(tenancies: all_tenancies, as_of: Date.current)

      attention_items = Dashboards::AttentionQuery.call(user: user, tenancies: all_tenancies, balances: balances)
      portfolio_summary = Dashboards::PortfolioSummaryQuery.call(
        user: user,
        date_range: ytd_range,
        properties: props,
        tenancies: all_tenancies,
        balances: balances
      )
      properties = properties_summary(props: props, balances: balances)
      recent_activity = Dashboards::RecentActivityQuery.call(user: user, through: Date.current, limit: 8)

      OverviewResult.new(
        attention_items: attention_items,
        portfolio_summary: portfolio_summary,
        properties: properties,
        recent_activity: recent_activity
      )
    end

    private

      attr_reader :user

      def ytd_range
        Accounting::DateRange.new(
          from: Date.current.beginning_of_year,
          through: Date.current
        )
      end

      def properties_summary(props:, balances:)
        props.map do |property|
          units = property.rentable_units.select(&:active?)
          occupied_units = units.count { |unit| unit.tenancies.any?(&:active?) }
          prop_tenancies = property.rentable_units.flat_map(&:tenancies)
          prop_balances = prop_tenancies.map { |t| balances[t.id] || 0 }
          due_cents = prop_balances.select(&:positive?).sum
          credit_cents = prop_balances.select(&:negative?).sum
          prop_balance_cents = if due_cents.positive?
            due_cents
          elsif credit_cents.negative?
            credit_cents
          else
            0
          end

          PropertyRow.new(
            property: property,
            occupied_units_count: occupied_units,
            total_units_count: units.size,
            balance_cents: prop_balance_cents
          )
        end
      end

      def empty_result
        empty_portfolio = Dashboards::PortfolioSummaryQuery.call(user: nil)
        OverviewResult.new(
          attention_items: [],
          portfolio_summary: empty_portfolio,
          properties: [],
          recent_activity: []
        )
      end
  end
end
