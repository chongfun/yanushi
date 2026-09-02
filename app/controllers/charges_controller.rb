class ChargesController < ApplicationController
  before_action :set_tenancy, only: %i[new create]
  before_action :set_charge, only: %i[show void]

  def new
    @charge = @tenancy.charges.new(
      charge_kind: "late_fee",
      charge_date: Date.current,
      due_on: Date.current
    )
  end

  def show
    @tenancy = @charge.tenancy
  end

  def create
    kind = charge_params[:charge_kind].presence || "other"

    unless Charges::CreateFeeService::ALLOWED_KINDS.include?(kind)
      @charge = @tenancy.charges.new(charge_params)
      @charge.errors.add(:charge_kind, "must be late_fee or other")
      return render_charge_failure
    end

    result = Charges::CreateFeeService.call(
      tenancy: @tenancy,
      charge_kind: kind,
      amount: charge_params[:amount],
      charge_date: charge_params[:charge_date],
      due_on: charge_params[:due_on],
      description: charge_params[:description]
    )

    if result.success?
      @charge = result.value!.data[:charge]
      respond_to do |format|
        format.html { redirect_to tenancy_path(@tenancy), notice: "Charge was successfully created.", status: :see_other }
        format.turbo_stream do
          @balance_cents = Accounting::TenancyBalanceQuery.balance_cents_as_of(tenancy: @tenancy, as_of: Date.current)
          @recent_activity_rows = Accounting::RecentTenantReceivableActivityQuery.call(tenancy: @tenancy)
          render "charges/create", formats: [ :turbo_stream ]
        end
      end
    else
      @charge = result.failure.data&.dig(:charge) || @tenancy.charges.new(charge_params)
      @charge.errors.add(:base, result.failure.error) if @charge.errors.empty?
      render_charge_failure
    end
  end

  def void
    reason = params[:reason].presence || "Voided via dashboard"
    result = Charges::VoidService.call(charge: @charge, reason: reason)

    respond_to do |format|
      if result.success?
        format.html { redirect_to @charge.tenancy, notice: "Charge ##{@charge.id} was successfully voided." }
        format.json { render json: { status: :ok, message: "Charge voided" } }
      else
        format.html { redirect_to @charge.tenancy, alert: "Failed to void charge: #{result.failure.error}" }
        format.json { render json: { error: result.failure.error }, status: :unprocessable_content }
      end
    end
  end

  private

    def set_tenancy
      @tenancy = authenticated_user.tenancies
                                  .includes({ tenancy_parties: :party }, { rentable_unit: :property })
                                  .find(params.expect(:tenancy_id))
    end

    def set_charge
      @charge = authenticated_user.charges.find(params.expect(:id))
    end

    def charge_params
      params.require(:charge).permit(
        :charge_kind, :amount, :charge_date, :due_on, :description,
        :service_period_start, :service_period_end
      )
    end

    def render_charge_failure
      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.turbo_stream do
          render turbo_stream: turbo_stream.update("modal-frame",
                   partial: "charges/form",
                   locals: { charge: @charge, tenancy: @tenancy, form_context: :dialog }),
                 status: :unprocessable_content
        end
      end
    end
end
