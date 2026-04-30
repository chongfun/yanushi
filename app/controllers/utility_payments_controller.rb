class UtilityPaymentsController < ApplicationController
  before_action :set_utility_payment, only: %i[ show edit update destroy ]

  # GET /utility_payments or /utility_payments.json
  def index
    @utility_payments = UtilityPayment.all
  end

  # GET /utility_payments/1 or /utility_payments/1.json
  def show
  end

  # GET /utility_payments/new
  def new
    @utility_payment = UtilityPayment.new
  end

  # GET /utility_payments/1/edit
  def edit
  end

  # POST /utility_payments or /utility_payments.json
  def create
    @utility_payment = UtilityPayment.new(utility_payment_params)

    respond_to do |format|
      if @utility_payment.save
        format.html { redirect_to @utility_payment, notice: "Utility payment was successfully created." }
        format.json { render :show, status: :created, location: @utility_payment }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @utility_payment.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /utility_payments/1 or /utility_payments/1.json
  def update
    respond_to do |format|
      if @utility_payment.update(utility_payment_params)
        format.html { redirect_to @utility_payment, notice: "Utility payment was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @utility_payment }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @utility_payment.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /utility_payments/1 or /utility_payments/1.json
  def destroy
    @utility_payment.destroy!

    respond_to do |format|
      format.html { redirect_to utility_payments_path, notice: "Utility payment was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_utility_payment
      @utility_payment = UtilityPayment.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def utility_payment_params
      params.expect(utility_payment: [ :tenant_id, :rental_property_id, :amount, :payment_date, :payment_method, :transaction_number ])
    end
end
