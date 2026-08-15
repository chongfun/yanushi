class RentableUnitsController < ApplicationController
  before_action :set_property
  before_action :set_rentable_unit, only: %i[edit update destroy]

  def new
    @rentable_unit = @property.rentable_units.new(active: true)
  end

  def edit
  end

  def create
    @rentable_unit = @property.rentable_units.new(rentable_unit_params)

    respond_to do |format|
      if @rentable_unit.save
        format.html { redirect_to @property, notice: "Rentable unit was successfully created." }
        format.json { render json: @rentable_unit, status: :created }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @rentable_unit.errors, status: :unprocessable_content }
      end
    end
  end

  def update
    respond_to do |format|
      if @rentable_unit.update(rentable_unit_params)
        format.html { redirect_to @property, notice: "Rentable unit was successfully updated.", status: :see_other }
        format.json { render json: @rentable_unit, status: :ok }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @rentable_unit.errors, status: :unprocessable_content }
      end
    end
  end

  def destroy
    if @rentable_unit.tenancies.exists?
      @rentable_unit.update!(active: false)
      respond_to do |format|
        format.html { redirect_to @property, notice: "Rentable unit has tenancy history and was deactivated instead of deleted.", status: :see_other }
        format.json { render json: @rentable_unit, status: :ok }
      end
    else
      @rentable_unit.destroy!
      respond_to do |format|
        format.html { redirect_to @property, notice: "Rentable unit was successfully destroyed.", status: :see_other }
        format.json { head :no_content }
      end
    end
  end

  private

    def set_property
      @property = authenticated_user.properties.find(params.expect(:property_id))
    end

    def set_rentable_unit
      @rentable_unit = @property.rentable_units.find(params.expect(:id))
    end

    def rentable_unit_params
      params.expect(rentable_unit: %i[name unit_identifier square_footage active])
    end
end
