class MoneyController < ApplicationController
  def show
    @properties = authenticated_user.properties.order(:address)
    selected_property = @properties.find_by(id: params[:property_id]) if params[:property_id].present?
    @selected_property_id = selected_property&.id

    @active_years = Accounting::ActiveYearsQuery.call(user: authenticated_user)
    year = params[:year].presence

    @activity_result = Accounting::PortfolioActivityQuery.call(
      user: authenticated_user,
      property_id: @selected_property_id,
      year: year,
      from: params[:from],
      through: params[:through],
      page: params[:page],
      per_page: 25
    )
  end
end
