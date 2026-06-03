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
      income = property.tenant_payments.sum(BigDecimal("0"), &:amount) || BigDecimal("0")
      expenses = property.expenses.sum(BigDecimal("0"), &:amount) || BigDecimal("0")
      active_leases = property.leases.select(&:active?)

      {
        property: property,
        income: income,
        expenses: expenses,
        net_income: income - expenses,
        lease_balances: active_leases.map { |lease| { lease: lease, balance: lease.current_balance } }
      }
    end
  end
end
