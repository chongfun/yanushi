class RentalPropertiesController < ApplicationController
  before_action :set_rental_property, only: %i[ show edit update destroy schedule_e ]

  # GET /rental_properties or /rental_properties.json
  def index
    @rental_properties = RentalProperty.all
  end

  # GET /rental_properties/1 or /rental_properties/1.json
  def show
    @year = params[:year].present? ? params[:year].to_i : Date.current.year
    @financial_items = @rental_property.financial_items(@year)
  end

  # GET /rental_properties/1/schedule_e
  def schedule_e
    @year = params[:year].present? ? params[:year].to_i : Date.current.year

    start_date = Date.new(@year, 1, 1)
    end_date   = start_date.end_of_year

    @rents_received = @rental_property.rent_payments
                        .where(payment_date: start_date..end_date)
                        .sum(:amount)

    @utility_reimbursements = @rental_property.utility_payments
                                .where(payment_date: start_date..end_date)
                                .sum(:amount)

    @total_income = @rents_received + @utility_reimbursements

    @expenses_by_category = @rental_property.expenses
                              .where(expense_date: start_date..end_date)
                              .group(:category)
                              .sum(:amount)

    @total_expenses = @expenses_by_category.values.sum
    @net_income = @total_income - @total_expenses
  end

  # GET /rental_properties/new
  def new
    @rental_property = RentalProperty.new
  end

  # GET /rental_properties/1/edit
  def edit
  end

  # POST /rental_properties or /rental_properties.json
  def create
    @rental_property = RentalProperty.new(rental_property_params)
    @rental_property.user = Current.session.user

    respond_to do |format|
      if @rental_property.save
        format.html { redirect_to @rental_property, notice: "Rental property was successfully created." }
        format.json { render :show, status: :created, location: @rental_property }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @rental_property.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /rental_properties/1 or /rental_properties/1.json
  def update
    respond_to do |format|
      if @rental_property.update(rental_property_params)
        format.html { redirect_to @rental_property, notice: "Rental property was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @rental_property }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @rental_property.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /rental_properties/1 or /rental_properties/1.json
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
      @rental_property = RentalProperty.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def rental_property_params
      params.expect(rental_property: [ :user_id, :address, :property_type, :square_footage ])
    end
end
