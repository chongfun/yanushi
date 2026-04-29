class DashboardsController < ApplicationController
  def index
    @properties = Current.user.rental_properties
  end
end
