class TenantPaymentsController < ApplicationController
  before_action :set_tenant_payment, only: %i[ show edit update destroy ]
  before_action :set_lease, only: %i[ new create ]

  # GET /tenant_payments or /tenant_payments.json
  def index
    @tenant_payments = TenantPayment.all
  end

  # GET /tenant_payments/1 or /tenant_payments/1.json
  def show
    respond_to do |format|
      format.html
      format.pdf do
        pdf = Prawn::Document.new
        pdf.text "Payment Receipt", size: 30, style: :bold
        pdf.move_down 20
        pdf.text "Payment Date: #{@tenant_payment.payment_date}"
        pdf.text "Amount: #{helpers.number_to_currency(@tenant_payment.amount)}"
        pdf.text "Method: #{@tenant_payment.payment_method}"
        pdf.text "Transaction Number: #{@tenant_payment.transaction_number}" if @tenant_payment.transaction_number.present?
        pdf.text "Property: #{@tenant_payment.lease.rental_property.address}"
        send_data pdf.render, filename: "receipt_#{@tenant_payment.id}.pdf", type: "application/pdf", disposition: "inline"
      end
    end
  end

  # GET /tenant_payments/new
  # GET /leases/:lease_id/tenant_payments/new
  def new
    @tenant_payment = TenantPayment.new
    @tenant_payment.lease = @lease if @lease
    if @lease
      owed = @lease.current_balance
      @tenant_payment.amount = owed < 0 ? owed.abs : 0
    end
    @tenant_payment.payment_date = Date.current
  end

  # GET /tenant_payments/1/edit
  def edit
  end

  # POST /tenant_payments or /tenant_payments.json
  # POST /leases/:lease_id/tenant_payments
  def create
    @tenant_payment = TenantPayment.new(tenant_payment_params)
    @tenant_payment.lease = @lease if @lease

    respond_to do |format|
      if @tenant_payment.save
        if @lease
          # Submitted from modal
          rental_property = @lease.rental_property
          @financial_items = rental_property.financial_items(Date.current.year)
          @year = Date.current.year

          format.turbo_stream {
            flash.now[:notice] = "Payment recorded successfully."
            render turbo_stream: [
              turbo_stream.action(:close_modal, "modal-container"),
              turbo_stream.update("property_financials", partial: "rental_properties/financials",
                locals: { rental_property: rental_property, financial_items: @financial_items, year: @year }),
              turbo_stream.update("active_lease_balances", partial: "rental_properties/lease_balances",
                locals: { rental_property: rental_property }),
              turbo_stream.append("flash-messages", partial: "shared/toast", locals: { type: :notice, message: "Payment recorded successfully." })
            ]
          }
          format.html { redirect_to rental_property, notice: "Payment recorded successfully." }
        else
          format.html { redirect_to @tenant_payment, notice: "Payment was successfully created." }
        end
        format.json { render :show, status: :created, location: @tenant_payment }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @tenant_payment.errors, status: :unprocessable_entity }
        format.turbo_stream {
          render turbo_stream: turbo_stream.update("modal-frame",
            partial: "tenant_payments/modal_form",
            locals: { tenant_payment: @tenant_payment, lease: @lease })
        }
      end
    end
  end

  # PATCH/PUT /tenant_payments/1 or /tenant_payments/1.json
  def update
    respond_to do |format|
      if @tenant_payment.update(tenant_payment_params)
        format.html { redirect_to @tenant_payment, notice: "Payment was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @tenant_payment }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @tenant_payment.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /tenant_payments/1 or /tenant_payments/1.json
  def destroy
    @tenant_payment.destroy!

    respond_to do |format|
      format.html { redirect_to tenant_payments_path, notice: "Payment was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_tenant_payment
      @tenant_payment = TenantPayment.find(params.expect(:id))
    end

    def set_lease
      @lease = Lease.find(params[:lease_id]) if params[:lease_id].present?
    end

    # Only allow a list of trusted parameters through.
    def tenant_payment_params
      params.expect(tenant_payment: [ :lease_id, :payment_date, :amount, :payment_method, :transaction_number ])
    end
end
