class RentPaymentsController < ApplicationController
  before_action :set_rent_payment, only: %i[ show edit update destroy ]
  before_action :set_scheduled_rent, only: %i[ new create ]

  # GET /rent_payments or /rent_payments.json
  def index
    @rent_payments = RentPayment.all
  end

  # GET /rent_payments/1 or /rent_payments/1.json
  def show
    respond_to do |format|
      format.html
      format.pdf do
        pdf = Prawn::Document.new
        pdf.text "Rent Receipt", size: 30, style: :bold
        pdf.move_down 20
        pdf.text "Payment Date: #{@rent_payment.payment_date}"
        pdf.text "Amount: #{helpers.number_to_currency(@rent_payment.amount)}"
        pdf.text "Method: #{@rent_payment.payment_method}"
        pdf.text "Transaction Number: #{@rent_payment.transaction_number}" if @rent_payment.transaction_number.present?
        pdf.text "Property: #{@rent_payment.scheduled_rent.lease.rental_property.address}"
        send_data pdf.render, filename: "receipt_#{@rent_payment.id}.pdf", type: "application/pdf", disposition: "inline"
      end
    end
  end

  # GET /rent_payments/new
  # GET /scheduled_rents/:scheduled_rent_id/rent_payments/new
  def new
    @rent_payment = RentPayment.new
    @rent_payment.scheduled_rent = @scheduled_rent if @scheduled_rent
    @rent_payment.amount = @scheduled_rent&.amount
    @rent_payment.payment_date = Date.current
  end

  # GET /rent_payments/1/edit
  def edit
  end

  # POST /rent_payments or /rent_payments.json
  # POST /scheduled_rents/:scheduled_rent_id/rent_payments
  def create
    @rent_payment = RentPayment.new(rent_payment_params)
    @rent_payment.scheduled_rent = @scheduled_rent if @scheduled_rent

    respond_to do |format|
      if @rent_payment.save
        if @scheduled_rent
          # Submitted from modal
          rental_property = @rent_payment.scheduled_rent.lease.rental_property
          @financial_items = rental_property.financial_items(Date.current.year)
          @year = Date.current.year
          
          format.turbo_stream {
            flash.now[:notice] = "Rent payment recorded successfully."
            render turbo_stream: [
              turbo_stream.action(:close_modal, "modal-container"),
              turbo_stream.update("property_financials", partial: "rental_properties/financials",
                locals: { rental_property: rental_property, financial_items: @financial_items, year: @year }),
              turbo_stream.append("flash-messages", partial: "shared/toast", locals: { type: :notice, message: "Rent payment recorded successfully." })
            ]
          }
          format.html { redirect_to rental_property, notice: "Rent payment recorded successfully." }
        else
          format.html { redirect_to @rent_payment, notice: "Rent payment was successfully created." }
        end
        format.json { render :show, status: :created, location: @rent_payment }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @rent_payment.errors, status: :unprocessable_entity }
        format.turbo_stream {
          render turbo_stream: turbo_stream.update("modal-frame",
            partial: "rent_payments/modal_form",
            locals: { rent_payment: @rent_payment, scheduled_rent: @scheduled_rent })
        }
      end
    end
  end

  # PATCH/PUT /rent_payments/1 or /rent_payments/1.json
  def update
    respond_to do |format|
      if @rent_payment.update(rent_payment_params)
        format.html { redirect_to @rent_payment, notice: "Rent payment was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @rent_payment }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @rent_payment.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /rent_payments/1 or /rent_payments/1.json
  def destroy
    @rent_payment.destroy!

    respond_to do |format|
      format.html { redirect_to rent_payments_path, notice: "Rent payment was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_rent_payment
      @rent_payment = RentPayment.find(params.expect(:id))
    end

    def set_scheduled_rent
      @scheduled_rent = ScheduledRent.find(params[:scheduled_rent_id]) if params[:scheduled_rent_id].present?
    end

    # Only allow a list of trusted parameters through.
    def rent_payment_params
      params.expect(rent_payment: [ :scheduled_rent_id, :payment_date, :amount, :payment_method, :transaction_number ])
    end
end
