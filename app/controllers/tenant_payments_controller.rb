class TenantPaymentsController < ApplicationController
  before_action :set_tenant_payment, only: %i[show]
  before_action :set_tenancy, only: %i[new create]
  before_action :set_form_data, only: %i[new create]

  def index
    @tenant_payments = authenticated_user.tenant_payments.includes(tenancy: { rentable_unit: :property })
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
    @tenant_payment.tenancy = @tenancy if @tenancy
    if tenancy = @tenancy
      owed = tenancy.current_balance
      tp = @tenant_payment
      tp.amount = owed > BigDecimal("0") ? owed : BigDecimal("0")
    end
    @tenant_payment.payment_date = Date.current
  end

  def create
    tenancy_id = tenant_payment_params[:tenancy_id]
    tenancy = @tenancy || (tenancy_id.present? ? authenticated_user.tenancies.find(tenancy_id) : nil)

    result = TenantPayments::CreateService.call(
      tenancy: tenancy,
      params: tenant_payment_params
    )

    respond_to do |format|
      if result.success?
        @tenant_payment = result.value!.data[:tenant_payment]
        if (t = @tenancy) && (property = t.property)
          # Submitted from modal
          year = @tenant_payment.payment_date&.year || Date.current.year
          @financial_items = property.financial_items(year)
          @year = year

          format.turbo_stream {
            flash.now[:notice] = "Payment recorded successfully."
            render turbo_stream: [
              turbo_stream.action(:close_modal, "modal-container"),
              turbo_stream.update("property_financials", partial: "properties/financials",
                                  locals: { property: property, financial_items: @financial_items, year: @year }),
              turbo_stream.update("active_lease_balances", partial: "properties/lease_balances",
                                  locals: { property: property }),
              turbo_stream.append("flash-messages", partial: "shared/toast", locals: { type: :notice, message: "Payment recorded successfully." })
            ]
          }
          format.html { redirect_to property, notice: "Payment recorded successfully." }
        else
          format.html { redirect_to @tenant_payment, notice: "Payment was successfully created." }
        end
        format.json { render :show, status: :created, location: @tenant_payment }
      else
        @tenant_payment = result.failure.data&.dig(:tenant_payment) || TenantPayment.new(tenant_payment_params)
        @tenant_payment.tenancy = tenancy if tenancy
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @tenant_payment.errors, status: :unprocessable_content }
        format.turbo_stream {
          render turbo_stream: turbo_stream.update("modal-frame",
                                                   partial: "tenant_payments/modal_form",
                                                   locals: { tenant_payment: @tenant_payment, tenancy: @tenancy })
        }
      end
    end
  end

  private

    def set_tenant_payment
      @tenant_payment = authenticated_user.tenant_payments.find(params.expect(:id))
    end

    def set_tenancy
      t_id = params[:tenancy_id] || params[:lease_id]
      @tenancy = authenticated_user.tenancies.find(t_id) if t_id.present?
    end

    def set_form_data
      @tenancies = authenticated_user.tenancies.includes({ rentable_unit: :property }, :parties)
    end

    def tenant_payment_params
      raw_params = params.require(:tenant_payment).permit(
        :tenancy_id, :lease_id, :payment_date, :amount, :payment_method, :transaction_number
      )
      if raw_params[:lease_id].present? && raw_params[:tenancy_id].blank?
        raw_params[:tenancy_id] = raw_params.delete(:lease_id)
      end
      raw_params
    end
end
