class ExpensesController < ApplicationController
  before_action :set_expense, only: %i[show correction correct void]
  before_action :set_nested_property, only: %i[new create]
  before_action :set_form_data, only: %i[new create correction correct]

  def index
    @expenses = authenticated_user.expenses
      .includes(:property, :rentable_unit, :superseded_by, :reimbursement_charges)
      .order(paid_on: :desc, created_at: :desc)
  end

  def show
  end

  def new
    @expense = Expense.new(
      property: @nested_property,
      paid_on: Date.current
    )
  end

  def create
    property = if (nested = @nested_property)
      if expense_params[:property_id].present? && expense_params[:property_id].to_s != nested.id.to_s
        @expense = Expense.new(expense_params)
        @expense.errors.add(:property, "must match route property")
        return render :new, status: :unprocessable_content
      end
      nested
    else
      authenticated_user.properties.find_by(id: expense_params[:property_id])
    end

    unless property
      @expense = Expense.new(expense_params)
      @expense.errors.add(:property, "must belong to your properties")
      return render :new, status: :unprocessable_content
    end

    rentable_unit = if expense_params[:rentable_unit_id].present?
      property.rentable_units.find_by(id: expense_params[:rentable_unit_id])
    end

    if expense_params[:rentable_unit_id].present? && rentable_unit.nil?
      @expense = Expense.new(expense_params)
      @expense.errors.add(:rentable_unit, "must belong to the selected property")
      return render :new, status: :unprocessable_content
    end

    result = Expenses::CreateService.call(
      property: property,
      rentable_unit: rentable_unit,
      expense_kind: expense_params[:expense_kind],
      amount: expense_params[:amount],
      paid_on: expense_params[:paid_on],
      vendor_name: expense_params[:vendor_name],
      external_reference: expense_params[:external_reference],
      description: expense_params[:description]
    )

    if result.success?
      @expense = result.value!.data[:expense]
      respond_to do |format|
        if (nested = @nested_property)
          year = @expense.paid_on&.year || Date.current.year
          date_range = Accounting::DateRange.parse(year: year)
          @financial_activity = Accounting::PropertyLedgerQuery.call(property: nested, date_range: date_range)
          @financial_summary = Accounting::PropertySummaryQuery.call(property: nested, date_range: date_range)
          @year = year

          format.turbo_stream {
            render turbo_stream: [
              turbo_stream.action(:close_modal, "modal-container"),
              turbo_stream.update("property_financials", partial: "properties/financials",
                                  locals: {
                                    property: nested,
                                    financial_activity: @financial_activity,
                                    financial_summary: @financial_summary,
                                    date_range: date_range,
                                    year: @year
                                  }),
              turbo_stream.append("flash-messages", partial: "shared/toast", locals: { type: :notice, message: "Expense recorded successfully." })
            ]
          }
          format.html { redirect_to nested, notice: "Expense was successfully created." }
        else
          format.html { redirect_to @expense, notice: "Expense was successfully created." }
        end
        format.json { render :show, status: :created, location: @expense }
      end
    else
      @expense = result.failure.data&.dig(:expense) || Expense.new(expense_params)
      @expense.errors.add(:base, result.failure.error) if @expense.errors.empty?

      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @expense.errors, status: :unprocessable_content }
        format.turbo_stream {
          render turbo_stream: turbo_stream.update("modal-frame",
                                                   partial: "expenses/modal_form",
                                                   locals: { expense: @expense, property: @nested_property })
        }
      end
    end
  end

  def correction
    if @expense.voided? || @expense.superseded?
      redirect_to @expense, alert: "This expense has already been corrected or voided."
    end
  end

  def correct
    if @expense.voided? || @expense.superseded?
      return redirect_to @expense, alert: "This expense has already been corrected or voided."
    end

    property = authenticated_user.properties.find_by(id: expense_params[:property_id])
    unless property
      @expense.errors.add(:property, "must belong to your properties")
      return render :correction, status: :unprocessable_content
    end

    rentable_unit = if expense_params[:rentable_unit_id].present?
      property.rentable_units.find_by(id: expense_params[:rentable_unit_id])
    end

    if expense_params[:rentable_unit_id].present? && rentable_unit.nil?
      @expense.errors.add(:rentable_unit, "must belong to the selected property")
      return render :correction, status: :unprocessable_content
    end

    result = Expenses::CorrectService.call(
      expense: @expense,
      property: property,
      rentable_unit: rentable_unit,
      expense_kind: expense_params[:expense_kind],
      amount: expense_params[:amount],
      paid_on: expense_params[:paid_on],
      vendor_name: expense_params[:vendor_name],
      external_reference: expense_params[:external_reference],
      description: expense_params[:description],
      user: authenticated_user
    )

    if result.success?
      replacement = result.value!.data[:replacement]
      redirect_to replacement, notice: "Expense was successfully corrected.", status: :see_other
    else
      @expense.errors.add(:base, result.failure.error) if @expense.errors.empty?
      render :correction, status: :unprocessable_content
    end
  end

  def void
    result = Expenses::VoidService.call(expense: @expense, user: authenticated_user)
    if result.success?
      redirect_to @expense, notice: "Expense was successfully voided and reversed.", status: :see_other
    else
      redirect_to @expense, alert: result.failure.error, status: :see_other
    end
  end

  private

    def set_expense
      @expense = authenticated_user.expenses.find(params.expect(:id))
    end

    def set_nested_property
      prop_id = params[:property_id] || params[:rental_property_id]
      @nested_property = authenticated_user.properties.find(prop_id) if prop_id.present?
    end

    def set_form_data
      user = authenticated_user
      @properties = user.properties.includes(:rentable_units).order(:address)
    end

    def expense_params
      params.require(:expense).permit(
        :property_id, :rentable_unit_id, :expense_kind, :amount,
        :paid_on, :vendor_name, :external_reference, :description
      )
    end
end
