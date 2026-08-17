class SecurityDepositsController < ApplicationController
  before_action :set_tenancy
  before_action :set_security_deposit, only: %i[show edit update receive refund apply]

  def show
    @transactions = @security_deposit.transactions.includes(:party, :charge, :superseded_by).order(occurred_on: :desc, id: :desc)
    @parties = authenticated_user.parties.order(:display_name)
    @active_charges = @tenancy.charges.posted.active.order(charge_date: :desc)
  end

  def new
    if @tenancy.security_deposit.present?
      redirect_to tenancy_security_deposit_path(@tenancy)
      return
    end

    @security_deposit = @tenancy.build_security_deposit(due_on: @tenancy.commencement_date)
  end

  def create
    result = SecurityDeposits::CreateService.call(
      tenancy: @tenancy,
      required_amount: security_deposit_params[:required_amount],
      due_on: security_deposit_params[:due_on]
    )

    if result.success?
      redirect_to tenancy_security_deposit_path(@tenancy), notice: "Security deposit requirement recorded."
    else
      @security_deposit = @tenancy.build_security_deposit(security_deposit_params)
      flash.now[:alert] = result.failure.error
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    if @security_deposit.transactions.exists?
      redirect_to tenancy_security_deposit_path(@tenancy), alert: "Deposit requirement cannot be edited after transactions exist."
    end
  end

  def update
    result = SecurityDeposits::UpdateService.call(
      security_deposit: @security_deposit,
      required_amount: security_deposit_params[:required_amount],
      due_on: security_deposit_params[:due_on]
    )

    if result.success?
      redirect_to tenancy_security_deposit_path(@tenancy), notice: "Security deposit requirement updated."
    else
      flash.now[:alert] = result.failure.error
      render :edit, status: :unprocessable_entity
    end
  end

  def receive
    party = authenticated_user.parties.find_by(id: params[:party_id])
    result = SecurityDepositTransactions::ReceiveService.call(
      security_deposit: @security_deposit,
      party: party,
      amount: params[:amount],
      occurred_on: params[:occurred_on],
      external_reference: params[:external_reference],
      memo: params[:memo]
    )

    if result.success?
      redirect_to tenancy_security_deposit_path(@tenancy), notice: "Security deposit payment received."
    else
      redirect_to tenancy_security_deposit_path(@tenancy), alert: result.failure.error
    end
  end

  def refund
    party = authenticated_user.parties.find_by(id: params[:party_id])
    result = SecurityDepositTransactions::RefundService.call(
      security_deposit: @security_deposit,
      party: party,
      amount: params[:amount],
      occurred_on: params[:occurred_on],
      external_reference: params[:external_reference],
      memo: params[:memo]
    )

    if result.success?
      redirect_to tenancy_security_deposit_path(@tenancy), notice: "Security deposit refund recorded."
    else
      redirect_to tenancy_security_deposit_path(@tenancy), alert: result.failure.error
    end
  end

  def apply
    charge = @tenancy.charges.find_by(id: params[:charge_id])
    result = SecurityDepositTransactions::ApplyService.call(
      security_deposit: @security_deposit,
      charge: charge,
      amount: params[:amount],
      occurred_on: params[:occurred_on],
      memo: params[:memo]
    )

    if result.success?
      redirect_to tenancy_security_deposit_path(@tenancy), notice: "Security deposit applied to charge."
    else
      redirect_to tenancy_security_deposit_path(@tenancy), alert: result.failure.error
    end
  end

  private

    def set_tenancy
      @tenancy = authenticated_user.tenancies.find(params[:tenancy_id])
    end

    def set_security_deposit
      deposit = @tenancy.security_deposit
      unless deposit
        redirect_to new_tenancy_security_deposit_path(@tenancy)
        return
      end
      @security_deposit = deposit
    end

    def security_deposit_params
      params.require(:security_deposit).permit(:required_amount, :due_on)
    end
end
