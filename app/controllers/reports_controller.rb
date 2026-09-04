class ReportsController < ApplicationController
  def show
    previous_year = Date.current.year - 1
    tax_year_obj = TaxReporting::TaxYear.parse(params[:year], default: previous_year) || TaxReporting::TaxYear.new(previous_year)
    @year = tax_year_obj.to_i
    @active_years = Accounting::ActiveYearsQuery.call(user: authenticated_user, additional_years: [ @year, previous_year, Date.current.year ])
    @statuses = Reports::ScheduleEStatusesQuery.call(user: authenticated_user, tax_year: @year)
    @needs_work_statuses, @ready_statuses = @statuses.partition(&:needs_work?)
  end
end
