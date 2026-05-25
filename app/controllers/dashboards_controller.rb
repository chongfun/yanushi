class DashboardsController < ApplicationController
  def index
    @properties = Current.session.user.rental_properties
      .includes(:expenses, :tenant_payments, leases: [ :tenants, :tenant_payments, :scheduled_rents, :tenant_charges ])
    @property_summaries = @properties.map { |property| dashboard_summary(property) }
  end

  private
    def dashboard_summary(property)
      income = property.tenant_payments.sum(&:amount)
      expenses = property.expenses.sum(&:amount)
      active_leases = property.leases.select { |lease| lease.active? }

      {
        property: property,
        income: income,
        expenses: expenses,
        net_income: income - expenses,
        lease_balances: active_leases.map { |lease| { lease: lease, balance: lease.current_balance } }
      }
    end
end
