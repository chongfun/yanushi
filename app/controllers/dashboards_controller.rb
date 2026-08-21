class DashboardsController < ApplicationController
  def index
    @properties = authenticated_user.properties
      .includes(:expenses, :receipts, tenancies: [ :parties, :receipts, :charges ])
    @property_summaries = Dashboards::PropertySummariesQuery.new(properties: @properties).call
  end
end
