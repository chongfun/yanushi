class MoneyController < ApplicationController
  def show
    @properties = authenticated_user.properties.order(:address)
    selected_property = @properties.find_by(id: params[:property_id]) if params[:property_id].present?
    @selected_property_id = selected_property&.id

    @active_years = Accounting::ActiveYearsQuery.call(user: authenticated_user)

    @date_range = Accounting::DateRange.parse(params)
    flash.now[:alert] = @date_range.errors.to_sentence unless @date_range.valid?

    @activity_result = Accounting::PortfolioActivityQuery.call(
      user: authenticated_user,
      property_id: @selected_property_id,
      date_range: @date_range,
      page: params[:page],
      per_page: 25
    )

    @summary = Accounting::PortfolioSummaryQuery.call(
      user: authenticated_user,
      property_id: @selected_property_id,
      date_range: @date_range
    )
  end
end
