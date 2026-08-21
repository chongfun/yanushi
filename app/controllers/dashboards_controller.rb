class DashboardsController < ApplicationController
  def index
    @properties = authenticated_user.properties
      .includes(:expenses, :tenant_payments, tenancies: [ :parties, :tenant_payments, :charges ])
    @property_summaries = Dashboards::PropertySummariesQuery.new(properties: @properties).call
  end
end
