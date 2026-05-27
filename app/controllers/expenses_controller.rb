class ExpensesController < ApplicationController
  before_action :set_expense, only: %i[ show edit update destroy ]
  before_action :set_rental_property, only: %i[ new create ]
  before_action :set_form_data, only: %i[ new edit create update ]

  def index
    @expenses = Current.session.user.expenses
  end


  def show
  end


  def new
    @expense = Expense.new
    @expense.rental_property = @rental_property if @rental_property
    @expense.expense_date = Date.current
  end


  def edit
  end


  def create
    permitted_params = expense_params
    property_id = permitted_params[:rental_property_id]
    if property_id.present?
      Current.session.user.rental_properties.find(property_id)
    end

    lease_id = permitted_params[:reimburse_lease_id]
    if lease_id.present?
      Current.session.user.leases.find(lease_id)
    end

    @expense = Expense.new(permitted_params)
    @expense.rental_property = @rental_property if @rental_property

    respond_to do |format|
      if save_expense
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
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @expense.errors, status: :unprocessable_content }
        format.turbo_stream {
          render turbo_stream: turbo_stream.update("modal-frame",
            partial: "expenses/modal_form",
            locals: { expense: @expense, rental_property: @rental_property })
        }
      end
    end
  end


  def update
    permitted_params = expense_params
    property_id = permitted_params[:rental_property_id]
    if property_id.present?
      Current.session.user.rental_properties.find(property_id)
    end

    lease_id = permitted_params[:reimburse_lease_id]
    if lease_id.present?
      Current.session.user.leases.find(lease_id)
    end

    @expense.assign_attributes(permitted_params)

    respond_to do |format|
      if save_expense
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
    # Use callbacks to share common setup or constraints between actions.
    def set_expense
      @expense = Current.session.user.expenses.find(params.expect(:id))
    end

    def set_rental_property
      @rental_property = Current.session.user.rental_properties.find(params[:rental_property_id]) if params[:rental_property_id].present?
    end

    def set_form_data
      user = Current.session.user
      @rental_properties = user.rental_properties.order(:address)
      @leases = user.leases.includes(:rental_property, :tenants)
    end

    # Only allow a list of trusted parameters through.
    def expense_params
      params.expect(expense: [ :rental_property_id, :category, :amount, :expense_date, :description, :tenant_reimbursable, :reimburse_lease_id, :reimburse_amount ])
    end

    def save_expense
      Expense.transaction do
        @expense.save!
        Expenses::TenantChargeService.call(@expense)
      end
      true
    rescue ActiveRecord::RecordInvalid
      false
    end
end
