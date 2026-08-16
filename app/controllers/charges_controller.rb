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
      return render :new, status: :unprocessable_content
    end

    result = Charges::CreateFeeService.call(
      tenancy: @tenancy,
      charge_kind: kind,
      amount: charge_params[:amount],
      amount_cents: charge_params[:amount_cents],
      charge_date: charge_params[:charge_date],
      due_on: charge_params[:due_on],
      description: charge_params[:description]
    )

    respond_to do |format|
      if result.success?
        @charge = result.value!.data[:charge]
        format.html { redirect_to @tenancy, notice: "Charge was successfully created." }
        format.json { render :show, status: :created, location: @charge }
      else
        @charge = result.failure.data&.dig(:charge) || @tenancy.charges.new(charge_params)
        @charge.errors.add(:base, result.failure.error) if @charge.errors.empty?
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @charge.errors, status: :unprocessable_content }
      end
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
      @tenancy = authenticated_user.tenancies.find(params.expect(:tenancy_id))
    end

    def set_charge
      @charge = authenticated_user.charges.find(params.expect(:id))
    end

    def charge_params
      params.require(:charge).permit(
        :charge_kind, :amount, :amount_cents, :charge_date, :due_on, :description,
        :service_period_start, :service_period_end
      )
    end
end
