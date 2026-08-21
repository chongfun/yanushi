class PropertiesController < ApplicationController
  before_action :set_property, only: %i[show edit update destroy schedule_e schedule_e_pdf]

  def index
    @properties = authenticated_user.properties.includes(:rentable_units)
  end

  def show
    @date_range = Accounting::DateRange.parse(params)
    unless @date_range.valid?
      flash.now[:alert] = @date_range.errors.to_sentence
    end
    @year = @date_range.year || Date.current.year
    @property = authenticated_user.properties.includes(
      :rentable_units,
      tenancies: :parties
    ).find(params.expect(:id))
    @financial_activity = Accounting::PropertyLedgerQuery.call(property: @property, date_range: @date_range)
    @financial_summary = Accounting::PropertySummaryQuery.call(property: @property, date_range: @date_range)
    @security_deposits_held_cents = Accounting::SecurityDepositBalanceQuery.call(property: @property)
    @active_years = Accounting::ActiveYearsQuery.call(property: @property, additional_years: [ @year ])
  end

  def schedule_e
    @year = params[:year].present? ? params[:year].to_i : Date.current.year
    summary = Properties::ScheduleESummaryQuery.new(property: @property).call(year: @year)

    @rents_received = summary.rents_received
    @utility_reimbursements = summary.utility_reimbursements
    @total_income = summary.total_income
    @expenses_by_category = summary.expenses_by_category
    @total_expenses = summary.total_expenses
    @net_income = summary.net_income
  end

  def schedule_e_pdf
    year = params[:year].present? ? params[:year].to_i : Date.current.year
    pdf_data = ScheduleEGenerator.new(@property, year).call

    send_data pdf_data,
              filename: "Schedule_E_#{@property.address.parameterize}_#{year}.pdf",
              type: "application/pdf",
              disposition: "attachment"
  rescue ScheduleEGenerator::TemplateMissingError => e
    redirect_to property_path(@property, year: year), alert: e.message
  end

  def new
    @property = Property.new(asset_type: "single_family")
  end

  def edit
  end

  def create
    result = Properties::CreateService.call(
      user: authenticated_user,
      property_params: property_params,
      unit_params: unit_params
    )

    if result.success?
      @property = result.value!.data[:property]
      respond_to do |format|
        format.html { redirect_to @property, notice: "Property was successfully created." }
        format.json { render :show, status: :created, location: @property }
      end
    else
      @property = (result.failure.data && result.failure.data[:property]) || Property.new(property_params)
      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @property.errors, status: :unprocessable_content }
      end
    end
  end

  def update
    respond_to do |format|
      if @property.update(property_params)
        format.html { redirect_to @property, notice: "Property was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @property }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @property.errors, status: :unprocessable_content }
      end
    end
  end

  def destroy
    if @property.destroy
      respond_to do |format|
        format.html { redirect_to properties_path, notice: "Property was successfully destroyed.", status: :see_other }
        format.json { head :no_content }
      end
    else
      respond_to do |format|
        format.html { redirect_to @property, alert: @property.errors.full_messages.to_sentence.presence || "Cannot delete property with active history.", status: :see_other }
        format.json { render json: @property.errors, status: :unprocessable_content }
      end
    end
  end

  private

    def set_property
      @property = authenticated_user.properties.find(params.expect(:id))
    end

    def property_params
      params.expect(property: %i[address asset_type square_footage])
    end

    def unit_params
      return nil unless params[:property][:unit].present?

      params.require(:property).require(:unit).permit(:name, :unit_identifier, :square_footage)
    end
end
