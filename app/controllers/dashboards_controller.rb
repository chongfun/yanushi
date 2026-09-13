class DashboardsController < ApplicationController
  def index
    @overview = Dashboards::OverviewQuery.call(user: authenticated_user)
  end
end
