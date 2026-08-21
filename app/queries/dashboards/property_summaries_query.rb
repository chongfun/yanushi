module Dashboards
  class PropertySummariesQuery
    def initialize(properties:)
      @properties = properties
    end

    def call
      properties.map { |property| summary_for(property) }
    end

    private

      attr_reader :properties

      def summary_for(property)
        income = property.receipts.active.sum(BigDecimal("0"), &:amount) || BigDecimal("0")
        expenses = property.expenses.sum(BigDecimal("0"), &:amount) || BigDecimal("0")
        active_tenancies = property.tenancies.select(&:active?)

        {
          property: property,
          income: income,
          expenses: expenses,
          net_income: income - expenses,
          tenancy_balances: active_tenancies.map { |tenancy| { tenancy: tenancy, lease: tenancy, balance: tenancy.current_balance } },
          lease_balances: active_tenancies.map { |tenancy| { tenancy: tenancy, lease: tenancy, balance: tenancy.current_balance } }
        }
      end
  end
end
