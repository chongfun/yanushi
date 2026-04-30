class ScheduledRentsController < ApplicationController
  before_action :set_scheduled_rent, only: %i[ show edit update destroy ]

  # GET /scheduled_rents or /scheduled_rents.json
  def index
    @scheduled_rents = ScheduledRent.all
  end

  # GET /scheduled_rents/1 or /scheduled_rents/1.json
  def show
  end

  # GET /scheduled_rents/new
  def new
    @scheduled_rent = ScheduledRent.new
  end

  # GET /scheduled_rents/1/edit
  def edit
  end

  # POST /scheduled_rents or /scheduled_rents.json
  def create
    @scheduled_rent = ScheduledRent.new(scheduled_rent_params)

    respond_to do |format|
      if @scheduled_rent.save
        format.html { redirect_to @scheduled_rent, notice: "Scheduled rent was successfully created." }
        format.json { render :show, status: :created, location: @scheduled_rent }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @scheduled_rent.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /scheduled_rents/1 or /scheduled_rents/1.json
  def update
    respond_to do |format|
      if @scheduled_rent.update(scheduled_rent_params)
        format.html { redirect_to @scheduled_rent, notice: "Scheduled rent was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @scheduled_rent }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @scheduled_rent.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /scheduled_rents/1 or /scheduled_rents/1.json
  def destroy
    @scheduled_rent.destroy!

    respond_to do |format|
      format.html { redirect_to scheduled_rents_path, notice: "Scheduled rent was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_scheduled_rent
      @scheduled_rent = ScheduledRent.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def scheduled_rent_params
      params.expect(scheduled_rent: [ :lease_id, :amount, :due_date ])
    end
end
