class RentalPropertiesController < ApplicationController
  before_action :set_rental_property, only: %i[ show edit update destroy schedule_e schedule_e_pdf ]

  def index
    @rental_properties = authenticated_user.rental_properties
  end


  def show
    @year = params[:year].present? ? params[:year].to_i : Date.current.year
    @rental_property = authenticated_user.rental_properties.includes(:expenses, :scheduled_rents, :tenant_payments, :tenant_charges, leases: [ :tenants, :tenant_payments, :scheduled_rents, :tenant_charges ]).find(params.expect(:id))
    @financial_items = @rental_property.financial_items(@year)
  end


  def schedule_e
    @year = params[:year].present? ? params[:year].to_i : Date.current.year
    summary = RentalProperties::ScheduleESummaryQuery.new(rental_property: @rental_property).call(year: @year)

    @rents_received = summary.rents_received
    @utility_reimbursements = summary.utility_reimbursements
    @total_income = summary.total_income
    @expenses_by_category = summary.expenses_by_category
    @total_expenses = summary.total_expenses
    @net_income = summary.net_income
  end


  def schedule_e_pdf
    year = params[:year].present? ? params[:year].to_i : Date.current.year
    pdf_data = ScheduleEGenerator.new(@rental_property, year).call

    send_data pdf_data,
      filename: "Schedule_E_#{@rental_property.address.parameterize}_#{year}.pdf",
      type: "application/pdf",
      disposition: "attachment"
  rescue ScheduleEGenerator::TemplateMissingError => e
    redirect_to rental_property_path(@rental_property, year: year), alert: e.message
  end




  def new
    @rental_property = RentalProperty.new
  end


  def edit
  end

  def create
    @rental_property = RentalProperty.new(rental_property_params)
    @rental_property.user = authenticated_user

    respond_to do |format|
      if @rental_property.save
        format.html { redirect_to @rental_property, notice: "Rental property was successfully created." }
        format.json { render :show, status: :created, location: @rental_property }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @rental_property.errors, status: :unprocessable_content }
      end
    end
  end


  def update
    respond_to do |format|
      if @rental_property.update(rental_property_params)
        format.html { redirect_to @rental_property, notice: "Rental property was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @rental_property }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @rental_property.errors, status: :unprocessable_content }
      end
    end
  end


  def destroy
    @rental_property.destroy!

    respond_to do |format|
      format.html { redirect_to rental_properties_path, notice: "Rental property was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_rental_property
      @rental_property = authenticated_user.rental_properties.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def rental_property_params
      params.expect(rental_property: [ :address, :property_type, :square_footage ])
    end
end
