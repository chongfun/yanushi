class ExpensesController < ApplicationController
  before_action :set_expense, only: %i[ show edit update destroy ]
  before_action :set_rental_property, only: %i[ new create ]

  # GET /expenses or /expenses.json
  def index
    @expenses = Expense.all
  end

  # GET /expenses/1 or /expenses/1.json
  def show
  end

  # GET /expenses/new
  # GET /rental_properties/:rental_property_id/expenses/new
  def new
    @expense = Expense.new
    @expense.rental_property = @rental_property if @rental_property
    @expense.expense_date = Date.current
  end

  # GET /expenses/1/edit
  def edit
  end

  # POST /expenses or /expenses.json
  # POST /rental_properties/:rental_property_id/expenses
  def create
    @expense = Expense.new(expense_params)
    @expense.rental_property = @rental_property if @rental_property

    respond_to do |format|
      if @expense.save
        if @rental_property
          # Submitted from modal
          year = @expense.expense_date&.year || Date.current.year
          @financial_items = @rental_property.financial_items(year)
          @year = year

          format.turbo_stream {
            render turbo_stream: [
              turbo_stream.action(:close_modal, "modal-container"),
              turbo_stream.update("property_financials", partial: "rental_properties/financials",
                locals: { rental_property: @rental_property, financial_items: @financial_items, year: @year }),
              turbo_stream.update("active_lease_balances", partial: "rental_properties/lease_balances",
                locals: { rental_property: @rental_property }),
              turbo_stream.append("flash-messages", partial: "shared/toast", locals: { type: :notice, message: "Expense recorded successfully." })
            ]
          }
          format.html { redirect_to @rental_property, notice: "Expense was successfully created." }
        else
          format.html { redirect_to @expense, notice: "Expense was successfully created." }
        end
        format.json { render :show, status: :created, location: @expense }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @expense.errors, status: :unprocessable_entity }
        format.turbo_stream {
          render turbo_stream: turbo_stream.update("modal-frame",
            partial: "expenses/modal_form",
            locals: { expense: @expense, rental_property: @rental_property })
        }
      end
    end
  end

  # PATCH/PUT /expenses/1 or /expenses/1.json
  def update
    respond_to do |format|
      if @expense.update(expense_params)
        format.html { redirect_to @expense, notice: "Expense was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @expense }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @expense.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /expenses/1 or /expenses/1.json
  def destroy
    @expense.destroy!

    respond_to do |format|
      format.html { redirect_to expenses_path, notice: "Expense was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_expense
      @expense = Expense.find(params.expect(:id))
    end

    def set_rental_property
      @rental_property = RentalProperty.find(params[:rental_property_id]) if params[:rental_property_id].present?
    end

    # Only allow a list of trusted parameters through.
    def expense_params
      params.expect(expense: [ :rental_property_id, :category, :amount, :expense_date, :description, :tenant_reimbursable, :reimburse_lease_id, :reimburse_amount ])
    end
end
