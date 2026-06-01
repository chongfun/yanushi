class ScheduledRentsController < ApplicationController
  before_action :set_scheduled_rent, only: %i[ show edit update destroy ]

  def index
    @scheduled_rents = authenticated_user.scheduled_rents.includes(lease: :rental_property)
  end

  def show
  end

  def new
    @scheduled_rent = ScheduledRent.new
  end

  def edit
  end

  def create
    @scheduled_rent = ScheduledRent.new(scheduled_rent_params)

    respond_to do |format|
      if @scheduled_rent.save
        format.html { redirect_to @scheduled_rent, notice: "Scheduled rent was successfully created." }
        format.json { render :show, status: :created, location: @scheduled_rent }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @scheduled_rent.errors, status: :unprocessable_content }
      end
    end
  end

  def update
    respond_to do |format|
      if @scheduled_rent.update(scheduled_rent_params)
        format.html { redirect_to @scheduled_rent, notice: "Scheduled rent was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @scheduled_rent }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @scheduled_rent.errors, status: :unprocessable_content }
      end
    end
  end

  def destroy
    @scheduled_rent.destroy!

    respond_to do |format|
      format.html { redirect_to scheduled_rents_path, notice: "Scheduled rent was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    def set_scheduled_rent
      @scheduled_rent = authenticated_user.scheduled_rents.find(params.expect(:id))
    end


    def scheduled_rent_params
      params.expect(scheduled_rent: [ :lease_id, :amount, :due_date ])
    end
end
