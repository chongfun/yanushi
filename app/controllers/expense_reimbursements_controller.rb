class ExpenseReimbursementsController < ApplicationController
  before_action :set_expense
  before_action :set_eligible_tenancies, only: %i[new create]

  def new
    if @expense.voided? || @expense.superseded?
      return redirect_to @expense, alert: "Cannot reimburse a voided or corrected expense."
    end

    if @expense.fully_reimbursed?
      return redirect_to @expense, alert: "This expense has already been fully reimbursed."
    end

    @charge = Charge.new(
      tenancy: @tenancies.first,
      amount: @expense.remaining_reimbursable_amount,
      charge_date: @expense.paid_on,
      due_on: @expense.paid_on,
      description: @expense.description
    )
  end

  def create
    tenancy_id = reimbursement_params[:tenancy_id]
    tenancy = @tenancies.find { |t| t.id.to_s == tenancy_id.to_s }

    unless tenancy
      @charge = Charge.new(reimbursement_params)
      @charge.errors.add(:tenancy, "must belong to the expense property or unit")
      return render :new, status: :unprocessable_content
    end

    result = Charges::CreateReimbursementService.call(
      expense: @expense,
      tenancy: tenancy,
      amount: reimbursement_params[:amount],
      charge_date: reimbursement_params[:charge_date],
      due_on: reimbursement_params[:due_on],
      description: reimbursement_params[:description]
    )

    if result.success?
      redirect_to @expense, notice: "Reimbursement charge was successfully created and posted."
    else
      @charge = result.failure.data&.dig(:charge) || Charge.new(reimbursement_params)
      @charge.errors.add(:base, result.failure.error) if @charge.errors.empty?
      render :new, status: :unprocessable_content
    end
  end

  private

    def set_expense
      @expense = authenticated_user.expenses.find(params.expect(:expense_id))
    end

    def set_eligible_tenancies
      @tenancies = if (unit = @expense.rentable_unit)
        unit.tenancies.includes({ rentable_unit: :property }, :parties)
      else
        @expense.property.tenancies.includes({ rentable_unit: :property }, :parties)
      end
    end

    def reimbursement_params
      params.require(:charge).permit(
        :tenancy_id, :amount, :charge_date, :due_on, :description
      )
    end
end
