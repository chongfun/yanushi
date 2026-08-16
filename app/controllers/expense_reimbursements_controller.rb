class ExpenseReimbursementsController < ApplicationController
  before_action :set_expense

  def new
    if @expense.fully_reimbursed?
      return redirect_to @expense, alert: "This expense has already been fully reimbursed."
    end

    @tenancies = @expense.property.tenancies.includes({ rentable_unit: :property }, :parties)
    @charge = Charge.new(
      tenancy: @tenancies.first,
      amount: @expense.remaining_reimbursable_amount,
      charge_date: @expense.expense_date,
      due_on: @expense.expense_date,
      description: @expense.description
    )
  end

  def create
    tenancy_id = reimbursement_params[:tenancy_id]
    tenancy = @expense.property.tenancies.find_by(id: tenancy_id)

    unless tenancy
      @charge = Charge.new(reimbursement_params)
      @charge.errors.add(:tenancy, "must belong to the expense property")
      @tenancies = @expense.property.tenancies.includes({ rentable_unit: :property }, :parties)
      return render :new, status: :unprocessable_content
    end

    result = Charges::CreateReimbursementService.call(
      expense: @expense,
      tenancy: tenancy,
      amount: reimbursement_params[:amount],
      amount_cents: reimbursement_params[:amount_cents],
      charge_date: reimbursement_params[:charge_date],
      due_on: reimbursement_params[:due_on],
      description: reimbursement_params[:description]
    )

    if result.success?
      redirect_to @expense, notice: "Reimbursement charge was successfully created and posted."
    else
      @charge = result.failure.data&.dig(:charge) || Charge.new(reimbursement_params)
      @charge.errors.add(:base, result.failure.error) if @charge.errors.empty?
      @tenancies = @expense.property.tenancies.includes({ rentable_unit: :property }, :parties)
      render :new, status: :unprocessable_content
    end
  end

  private

    def set_expense
      @expense = authenticated_user.expenses.find(params.expect(:expense_id))
    end

    def reimbursement_params
      params.require(:charge).permit(
        :tenancy_id, :amount, :amount_cents, :charge_date, :due_on, :description
      )
    end
end
