class DashboardsController < ApplicationController
  def index
    @properties = Current.session.user.rental_properties
      .includes(:expenses, :tenant_payments, leases: [ :tenants, :tenant_payments, :scheduled_rents, :tenant_charges ])
  end
end
