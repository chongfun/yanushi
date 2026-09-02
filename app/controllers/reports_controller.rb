class ReportsController < ApplicationController
  def show
    @properties = authenticated_user.properties
  end
end
