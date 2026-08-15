class ScheduledRentsController < ApplicationController
  before_action :set_scheduled_rent, only: %i[show]

  def index
    @scheduled_rents = authenticated_user.scheduled_rents.includes(tenancy: { rentable_unit: :property })
  end

  def show
  end

  private

  def set_scheduled_rent
    @scheduled_rent = authenticated_user.scheduled_rents.find(params.expect(:id))
  end
end
