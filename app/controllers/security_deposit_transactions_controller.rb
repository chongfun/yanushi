class SecurityDepositTransactionsController < ApplicationController
  before_action :set_transaction

  def show
    @journal_entries = @transaction.journal_entries.includes(postings: :account).order(:occurred_on, :id)
  end

  def correction
    if @transaction.voided? || @transaction.superseded?
      redirect_to security_deposit_transaction_path(@transaction), alert: "This transaction cannot be corrected."
      return
    end

    @parties = authenticated_user.parties.order(:display_name)
    @active_charges = load_active_charges
  end

  def correct
    result = SecurityDepositTransactions::CorrectService.call(
      transaction: @transaction,
      amount: transaction_params[:amount],
      occurred_on: transaction_params[:occurred_on],
      party_id: transaction_params[:party_id],
      charge_id: transaction_params[:charge_id],
      external_reference: transaction_params[:external_reference],
      memo: transaction_params[:memo]
    )

    if result.success?
      replacement = result.value!.data[:replacement]
      redirect_to security_deposit_transaction_path(replacement), notice: "Deposit transaction corrected successfully."
    else
      @parties = authenticated_user.parties.order(:display_name)
      @active_charges = load_active_charges
      flash.now[:alert] = result.failure.error
      render :correction, status: :unprocessable_entity
    end
  end

  def void
    result = SecurityDepositTransactions::VoidService.call(
      transaction: @transaction,
      reason: params[:reason]
    )

    if result.success?
      redirect_to tenancy_security_deposit_path(@transaction.tenancy), notice: "Deposit transaction voided successfully."
    else
      redirect_to security_deposit_transaction_path(@transaction), alert: result.failure.error
    end
  end

  private

    def load_active_charges
      tenancy = @transaction.tenancy
      if tenancy
        tenancy.charges.posted.active.order(charge_date: :desc)
      else
        Charge.none
      end
    end

    def set_transaction
      @transaction = SecurityDepositTransaction.joins(security_deposit: { tenancy: { rentable_unit: :property } })
                                              .where(properties: { user_id: authenticated_user.id })
                                              .find(params[:id])
    end

    def transaction_params
      params.require(:security_deposit_transaction).permit(
        :amount, :occurred_on, :party_id, :charge_id, :external_reference, :memo
      )
    end
end
