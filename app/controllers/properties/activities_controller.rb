module Properties
  class ActivitiesController < ApplicationController
    before_action :set_property

    def show
      @date_range = Accounting::DateRange.parse(params)
      unless @date_range.valid?
        flash.now[:alert] = @date_range.errors.to_sentence
      end
      @year = @date_range.year || Date.current.year
      @activity_result = Accounting::PortfolioActivityQuery.call(
        user: authenticated_user,
        property_id: @property.id,
        date_range: @date_range,
        page: params[:page],
        per_page: 25
      )
      @financial_summary = Accounting::PropertySummaryQuery.call(property: @property, date_range: @date_range)
      @active_years = Accounting::ActiveYearsQuery.call(property: @property, additional_years: [ @year ])
    end

    private

      def set_property
        @property = authenticated_user.properties.includes(rentable_units: :tenancies).find(params.expect(:property_id))
      end
  end
end
