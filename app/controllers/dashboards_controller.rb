class DashboardsController < ApplicationController
  def index
    @properties = Current.session.user.rental_properties
  end
end
