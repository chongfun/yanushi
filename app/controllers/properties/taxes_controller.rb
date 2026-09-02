module Properties
  class TaxesController < ApplicationController
    before_action :set_property

    def show
      default_year = Date.current.year
      tax_year_obj = TaxReporting::TaxYear.parse(params[:year], default: default_year) || TaxReporting::TaxYear.new(default_year)
      @year = tax_year_obj.to_i
      @tax_profile = @property.tax_profile_for(@year)
      @status = Reports::ScheduleEStatusesQuery.status_for(property: @property, tax_year: @year)
      @active_years = Accounting::ActiveYearsQuery.call(property: @property, additional_years: [ @year ])
      @pdf_available = ScheduleEGenerator.template_available?(@year)
    end

    private

      def set_property
        @property = authenticated_user.properties.includes(rentable_units: :tenancies).find(params.expect(:property_id))
      end
  end
end
