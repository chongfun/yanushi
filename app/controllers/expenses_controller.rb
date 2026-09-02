class ExpensesController < ApplicationController
  before_action :set_expense, only: %i[show correction correct void]
  before_action :set_nested_property, only: %i[new create]
  before_action :set_form_data, only: %i[new create correction correct]

  def index
    page = [ params[:page].to_i, 1 ].max
    @per_page = 25
    scope = authenticated_user.expenses
                              .includes(:property, :rentable_unit, :superseded_by, :superseded_expense, :reimbursement_charges)
                              .order(paid_on: :desc, created_at: :desc)
    @total_count = scope.count
    @total_pages = @total_count.zero? ? 0 : (@total_count.to_f / @per_page).ceil
    @page = @total_pages > 0 ? [ page, @total_pages ].min : page
    @expenses = scope.limit(@per_page).offset((@page - 1) * @per_page)
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
        @expense.property = nil
        @expense.errors.add(:property_id, "must match route property")
        flash.now[:alert] = "Property must match route property"
        return render_create_failure
      end
      nested
    else
      authenticated_user.properties.find_by(id: expense_params[:property_id])
    end

    unless property
      @expense = Expense.new(expense_params)
      @expense.property = nil
      @expense.errors.add(:property_id, "must belong to your properties")
      flash.now[:alert] = "Property must belong to your properties"
      return render_create_failure
    end

    rentable_unit = if expense_params[:rentable_unit_id].present?
      property.rentable_units.find_by(id: expense_params[:rentable_unit_id])
    end

    if expense_params[:rentable_unit_id].present? && rentable_unit.nil?
      @expense = Expense.new(expense_params)
      @expense.errors.add(:rentable_unit_id, "must belong to the selected property")
      flash.now[:alert] = "Unit must belong to the selected property"
      return render_create_failure
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
          format.html { redirect_to property_activity_path(nested), notice: "Expense was successfully created." }
          format.turbo_stream do
            if params[:format] != "html"
              ytd_range = Accounting::DateRange.new(
                from: Date.current.beginning_of_year,
                through: Date.current
              )
              @ytd_summary = Accounting::PropertySummaryQuery.call(property: nested, date_range: ytd_range)
              recent_range = Accounting::DateRange.new(through: Date.current)
              @recent_activity = Accounting::PropertyLedgerQuery.call(property: nested, date_range: recent_range, limit: 5)
              @security_deposits_held_cents = Accounting::SecurityDepositBalanceQuery.call(property: nested)
              render "expenses/create", formats: [ :turbo_stream ]
            else
              redirect_to property_activity_path(nested), notice: "Expense was successfully created.", status: :see_other
            end
          end
        else
          format.html { redirect_to @expense, notice: "Expense was successfully created." }
          format.turbo_stream { redirect_to @expense, notice: "Expense was successfully created.", status: :see_other }
        end
        format.json { render :show, status: :created, location: @expense }
      end
    else
      @expense = result.failure.data&.dig(:expense) || Expense.new(expense_params)
      @expense.valid?
      error_msg = result.failure.error.to_s
      err_lower = error_msg.downcase
      if err_lower.include?("amount")
        @expense.errors.add(:amount, error_msg)
      elsif err_lower.include?("category") || err_lower.include?("kind")
        @expense.errors.add(:expense_kind, error_msg)
      elsif err_lower.include?("date") || err_lower.include?("paid")
        @expense.errors.add(:paid_on, error_msg)
      elsif err_lower.include?("property")
        @expense.errors.add(:property_id, error_msg)
      elsif err_lower.include?("unit")
        @expense.errors.add(:rentable_unit_id, error_msg)
      elsif err_lower.include?("vendor")
        @expense.errors.add(:vendor_name, error_msg)
      elsif err_lower.include?("reference")
        @expense.errors.add(:external_reference, error_msg)
      else
        @expense.errors.add(:base, error_msg)
      end
      flash.now[:alert] = result.failure.error
      render_create_failure
    end
  end

  def correction
    if @expense.voided? || @expense.superseded?
      return redirect_to @expense, alert: "This expense has already been corrected or voided."
    end

    @replacement_expense = @expense
  end

  def correct
    if @expense.voided? || @expense.superseded?
      return redirect_to @expense, alert: "This expense has already been corrected or voided."
    end

    @replacement_expense = Expense.new(expense_params)

    # Preserve current property if omitted
    property = if expense_params.key?(:property_id)
      if expense_params[:property_id].present?
        authenticated_user.properties.find_by(id: expense_params[:property_id])
      end
    else
      @expense.property
    end

    unless property
      @replacement_expense.property = nil
      @replacement_expense.errors.add(:property_id, "must belong to your properties")
      flash.now[:alert] = "Please fix the errors below."
      return render :correction, status: :unprocessable_content
    end

    @replacement_expense.property = property

    # Preserve current unit if omitted
    rentable_unit = if expense_params.key?(:rentable_unit_id)
      if expense_params[:rentable_unit_id].present?
        property.rentable_units.find_by(id: expense_params[:rentable_unit_id])
      end
    else
      @expense.rentable_unit
    end

    if expense_params[:rentable_unit_id].present? && rentable_unit.nil?
      @replacement_expense.errors.add(:rentable_unit_id, "must belong to the selected property")
      flash.now[:alert] = "Please fix the errors below."
      return render :correction, status: :unprocessable_content
    end

    @replacement_expense.rentable_unit = rentable_unit

    # Default omitted fields to current values for validation
    @replacement_expense.expense_kind = @expense.expense_kind unless expense_params.key?(:expense_kind)
    @replacement_expense.amount_cents = @expense.amount_cents unless expense_params.key?(:amount)
    @replacement_expense.paid_on = @expense.paid_on unless expense_params.key?(:paid_on)

    @replacement_expense.valid?

    # Reject submitted blank required fields
    if expense_params.key?(:expense_kind) && expense_params[:expense_kind].blank?
      @replacement_expense.errors.add(:expense_kind, "can't be blank")
    end

    if expense_params.key?(:amount) && expense_params[:amount].blank?
      @replacement_expense.errors.add(:amount, "can't be blank")
    end

    if expense_params.key?(:paid_on) && expense_params[:paid_on].blank?
      @replacement_expense.errors.add(:paid_on, "can't be blank")
    end

    if @replacement_expense.errors.any?
      flash.now[:alert] = "Please fix the errors below."
      return render :correction, status: :unprocessable_content
    end

    result = Expenses::CorrectService.call(
      expense: @expense,
      property: property,
      rentable_unit: rentable_unit,
      expense_kind: expense_params[:expense_kind] || @expense.expense_kind,
      amount: expense_params[:amount],
      amount_cents: expense_params.key?(:amount) ? nil : @expense.amount_cents,
      paid_on: expense_params[:paid_on] || @expense.paid_on,
      vendor_name: expense_params.key?(:vendor_name) ? expense_params[:vendor_name] : :not_set,
      external_reference: expense_params.key?(:external_reference) ? expense_params[:external_reference] : :not_set,
      description: expense_params.key?(:description) ? expense_params[:description] : :not_set,
      user: authenticated_user
    )

    if result.success?
      replacement = result.value!.data[:replacement]
      redirect_to replacement, notice: "Expense was successfully corrected.", status: :see_other
    else
      @replacement_expense.valid?
      error_msg = result.failure.error.to_s
      err_lower = error_msg.downcase
      if err_lower.include?("amount")
        @replacement_expense.errors.add(:amount, error_msg)
      elsif err_lower.include?("category") || err_lower.include?("kind")
        @replacement_expense.errors.add(:expense_kind, error_msg)
      elsif err_lower.include?("date") || err_lower.include?("paid")
        @replacement_expense.errors.add(:paid_on, error_msg)
      elsif err_lower.include?("property")
        @replacement_expense.errors.add(:property_id, error_msg)
      elsif err_lower.include?("unit")
        @replacement_expense.errors.add(:rentable_unit_id, error_msg)
      elsif err_lower.include?("vendor")
        @replacement_expense.errors.add(:vendor_name, error_msg)
      elsif err_lower.include?("reference")
        @replacement_expense.errors.add(:external_reference, error_msg)
      else
        @replacement_expense.errors.add(:base, error_msg)
      end
      flash.now[:alert] = result.failure.error
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

    def render_create_failure
      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.turbo_stream do
          if @nested_property && params[:format] != "html"
            render turbo_stream: turbo_stream.update(
              "modal-frame",
              partial: "expenses/form",
              locals: {
                expense: @expense,
                form_context: :dialog,
                nested_property: @nested_property,
                properties: @properties
              }
            ), status: :unprocessable_content
          else
            render :new, formats: [ :html ], content_type: "text/html", status: :unprocessable_content
          end
        end
        format.json { render json: @expense.errors, status: :unprocessable_content }
      end
    end
end
