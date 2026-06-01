class TenantPaymentsController < ApplicationController
  before_action :set_tenant_payment, only: %i[ show edit update destroy ]
  before_action :set_lease, only: %i[ new create ]
  before_action :set_form_data, only: %i[ new edit create update ]

  def index
    @tenant_payments = authenticated_user.tenant_payments.includes(lease: :rental_property)
  end

  def show
    respond_to do |format|
      format.html
      format.pdf do
        pdf_data = TenantPayments::ReceiptPdfService.call(tenant_payment: @tenant_payment, view_context: helpers)
        send_data pdf_data, filename: "receipt_#{@tenant_payment.id}.pdf", type: "application/pdf", disposition: "inline"
      end
    end
  end


  def new
    @tenant_payment = TenantPayment.new
    @tenant_payment.lease = @lease if @lease
    if lease = @lease
      owed = lease.current_balance
      @tenant_payment.amount = owed < 0 ? owed.abs : 0.to_d
    end
    @tenant_payment.payment_date = Date.current
  end

  def edit
  end


  def create
    lease_id = tenant_payment_params[:lease_id]
    if lease_id.present?
      authenticated_user.leases.find(lease_id)
    end

    @tenant_payment = TenantPayment.new(tenant_payment_params)
    @tenant_payment.lease = @lease if @lease

    respond_to do |format|
      if @tenant_payment.save
        if lease = @lease
          # Submitted from modal
          rental_property = lease.rental_property
          year = @tenant_payment.payment_date&.year || Date.current.year
          @financial_items = rental_property.financial_items(year)
          @year = year

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
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @tenant_payment.errors, status: :unprocessable_content }
        format.turbo_stream {
          render turbo_stream: turbo_stream.update("modal-frame",
            partial: "tenant_payments/modal_form",
            locals: { tenant_payment: @tenant_payment, lease: @lease })
        }
      end
    end
  end

  def update
    lease_id = tenant_payment_params[:lease_id]
    if lease_id.present?
      authenticated_user.leases.find(lease_id)
    end

    respond_to do |format|
      if @tenant_payment.update(tenant_payment_params)
        format.html { redirect_to @tenant_payment, notice: "Payment was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @tenant_payment }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @tenant_payment.errors, status: :unprocessable_content }
      end
    end
  end

  def destroy
    @tenant_payment.destroy!

    respond_to do |format|
      format.html { redirect_to tenant_payments_path, notice: "Payment was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    def set_tenant_payment
      @tenant_payment = authenticated_user.tenant_payments.find(params.expect(:id))
    end

    def set_lease
      @lease = authenticated_user.leases.find(params[:lease_id]) if params[:lease_id].present?
    end

    def set_form_data
      @leases = authenticated_user.leases.includes(:rental_property, :tenants)
    end


    def tenant_payment_params
      params.expect(tenant_payment: [ :lease_id, :payment_date, :amount, :payment_method, :transaction_number ])
    end
end
