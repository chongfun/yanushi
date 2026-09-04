class PropertiesController < ApplicationController
  before_action :set_property, only: %i[edit update destroy schedule_e schedule_e_pdf]

  def index
    respond_to do |format|
      format.html { redirect_to portfolio_path, status: :moved_permanently }
      format.json { @properties = authenticated_user.properties.includes(:rentable_units) }
    end
  end

  def show
    @property = authenticated_user.properties.includes(
      rentable_units: { tenancies: [ :parties, :tenancy_parties, :rent_terms ] }
    ).find(params.expect(:id))
    @tenancies = @property.rentable_units.flat_map(&:tenancies)
    @balances = Accounting::TenancyBalancesQuery.call(tenancies: @tenancies)
    @security_deposits_held_cents = Accounting::SecurityDepositBalanceQuery.call(property: @property)
    ytd_range = Accounting::DateRange.new(
      from: Date.current.beginning_of_year,
      through: Date.current
    )
    @ytd_summary = Accounting::PropertySummaryQuery.call(property: @property, date_range: ytd_range)
    recent_range = Accounting::DateRange.new(through: Date.current)
    @recent_activity = Accounting::PropertyLedgerQuery.call(property: @property, date_range: recent_range, limit: 5)
  end

  def schedule_e
    tax_year_obj = TaxReporting::TaxYear.parse(params[:year])
    unless tax_year_obj
      redirect_to schedule_e_property_path(@property, year: Date.current.year),
                  alert: "Invalid tax year '#{params[:year]}'. Displaying #{Date.current.year}."
      return
    end

    @year = tax_year_obj.to_i
    @schedule_e_result = TaxReporting::ScheduleEQuery.call(property: @property, tax_year: @year)
    @tax_profile = @schedule_e_result.tax_profile
    @form_definition = TaxReporting::ScheduleEFormDefinition.for(@year)
  end

  def schedule_e_pdf
    tax_year_obj = TaxReporting::TaxYear.parse(params[:year])
    unless tax_year_obj
      redirect_to schedule_e_property_path(@property, year: Date.current.year),
                  alert: "Invalid tax year '#{params[:year]}'."
      return
    end

    year = tax_year_obj.to_i
    pdf_data = ScheduleEGenerator.new(@property, year).call

    send_data pdf_data,
              filename: "Schedule_E_Worksheet_#{@property.address.parameterize}_#{year}.pdf",
              type: "application/pdf",
              disposition: "attachment"
  rescue ScheduleEGenerator::TemplateMissingError, ScheduleEGenerator::TaxProfileRequiredError, ScheduleEGenerator::TaxReviewRequiredError => e
    redirect_to schedule_e_property_path(@property, year: year), alert: e.message
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
        format.html { redirect_to portfolio_path, notice: "Property was successfully destroyed.", status: :see_other }
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
