class ExpensesController < ApplicationController
  before_action :set_expense, only: %i[show edit update destroy]
  before_action :set_property, only: %i[new create]
  before_action :set_form_data, only: %i[new edit create update]

  def index
    @expenses = authenticated_user.expenses
  end

  def show
  end

  def new
    @expense = Expense.new
    @expense.property = @property if @property
    @expense.expense_date = Date.current
  end

  def edit
  end

  def create
    permitted_params = expense_params
    property_id = permitted_params[:property_id]
    authenticated_user.properties.find(property_id) if property_id.present?

    tenancy_id = permitted_params[:reimburse_tenancy_id]
    authenticated_user.tenancies.find(tenancy_id) if tenancy_id.present?

    @expense = Expense.new(permitted_params)
    @expense.property = @property if @property

    respond_to do |format|
      result = Expenses::SaveService.call(expense: @expense)
      if result.success?
        if property = @property
          # Submitted from modal
          year = @expense.expense_date&.year || Date.current.year
          @financial_items = property.financial_items(year)
          @year = year

          format.turbo_stream {
            render turbo_stream: [
              turbo_stream.action(:close_modal, "modal-container"),
              turbo_stream.update("property_financials", partial: "properties/financials",
                                  locals: { property: property, financial_items: @financial_items, year: @year }),
              turbo_stream.update("active_lease_balances", partial: "properties/lease_balances",
                                  locals: { property: property }),
              turbo_stream.append("flash-messages", partial: "shared/toast", locals: { type: :notice, message: "Expense recorded successfully." })
            ]
          }
          format.html { redirect_to property, notice: "Expense was successfully created." }
        else
          format.html { redirect_to @expense, notice: "Expense was successfully created." }
        end
        format.json { render :show, status: :created, location: @expense }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @expense.errors, status: :unprocessable_content }
        format.turbo_stream {
          render turbo_stream: turbo_stream.update("modal-frame",
                                                   partial: "expenses/modal_form",
                                                   locals: { expense: @expense, property: @property })
        }
      end
    end
  end

  def update
    permitted_params = expense_params
    property_id = permitted_params[:property_id]
    authenticated_user.properties.find(property_id) if property_id.present?

    tenancy_id = permitted_params[:reimburse_tenancy_id]
    authenticated_user.tenancies.find(tenancy_id) if tenancy_id.present?

    @expense.assign_attributes(permitted_params)

    respond_to do |format|
      result = Expenses::SaveService.call(expense: @expense)
      if result.success?
        format.html { redirect_to @expense, notice: "Expense was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @expense }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @expense.errors, status: :unprocessable_content }
      end
    end
  end

  def destroy
    @expense.destroy!

    respond_to do |format|
      format.html { redirect_to expenses_path, notice: "Expense was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private

    def set_expense
      @expense = authenticated_user.expenses.find(params.expect(:id))
    end

    def set_property
      prop_id = params[:property_id] || params[:rental_property_id]
      @property = authenticated_user.properties.find(prop_id) if prop_id.present?
    end

    def set_form_data
      user = authenticated_user
      @properties = user.properties.order(:address)
      @tenancies = user.tenancies.includes({ rentable_unit: :property }, :parties)
    end

    def expense_params
      params.require(:expense).permit(
        :property_id, :category, :amount, :expense_date, :description,
        :tenant_reimbursable, :reimburse_tenancy_id, :reimburse_amount
      )
    end
end
