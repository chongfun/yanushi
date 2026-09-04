class TenanciesController < ApplicationController
  before_action :set_tenancy, only: %i[show edit update destroy statement]
  before_action :set_form_data, only: %i[new edit create update]

  def index
    page = [ params[:page].to_i, 1 ].max
    @per_page = 25
    scope = authenticated_user.tenancies
                              .includes({ rentable_unit: :property }, { tenancy_parties: :party }, :rent_terms)
                              .order(commencement_date: :desc, id: :desc)
    @total_count = scope.count
    @total_pages = @total_count.zero? ? 0 : (@total_count.to_f / @per_page).ceil
    @page = @total_pages > 0 ? [ page, @total_pages ].min : page
    @tenancies = scope.limit(@per_page).offset((@page - 1) * @per_page).to_a
    @balances = Accounting::TenancyBalancesQuery.call(tenancies: @tenancies)
  end

  def show
    @current_rent_term = @tenancy.primary_rent_term
    @balance_cents = Accounting::TenancyBalanceQuery.balance_cents_as_of(tenancy: @tenancy, as_of: Date.current)
    @security_deposit_held_cents = Accounting::SecurityDepositBalanceQuery.call(tenancy: @tenancy, as_of: Date.current)
    @recent_activity_rows = Accounting::RecentTenantReceivableActivityQuery.call(
      tenancy: @tenancy,
      limit: 5,
      as_of: Date.current
    )
  end

  def statement
    @date_range = Accounting::DateRange.parse(params)
    unless @date_range.valid?
      flash.now[:alert] = @date_range.errors.to_sentence
    end
    @view_mode = params[:view] == "all" ? "all" : "receivable"
    if @view_mode == "all"
      @financial_activity = Accounting::TenancyActivityQuery.call(
        tenancy: @tenancy,
        date_range: @date_range
      )
    else
      @statement = Accounting::TenantReceivableActivityQuery.call(
        tenancy: @tenancy,
        date_range: @date_range
      )
    end

    respond_to do |format|
      format.html
      format.pdf do
        unless statement_export_blocked?
          send_data statement_pdf,
                    filename: statement_export_filename("pdf"),
                    type: "application/pdf",
                    disposition: "attachment"
        end
      end
      format.csv do
        unless statement_export_blocked?
          send_data statement_csv,
                    filename: statement_export_filename("csv"),
                    type: "text/csv",
                    disposition: "attachment"
        end
      end
    end
  end

  def new
    rentable_unit = if params[:rentable_unit_id].present?
      RentableUnit.joins(:property)
                  .where(properties: { user_id: authenticated_user.id }, id: params[:rentable_unit_id])
                  .first
    end

    @tenancy = Tenancy.new(
      rentable_unit: rentable_unit,
      commencement_date: Date.current,
      agreement_type: "fixed_term",
      late_period_days: 0
    )
  end

  def edit
  end

  def create
    result = Tenancies::CreateService.call(
      user: authenticated_user,
      tenancy_params: tenancy_create_params,
      participants: participants_params,
      initial_rent: initial_rent_params
    )

    if result.success?
      @tenancy = result.value!.data[:tenancy]
      respond_to do |format|
        format.html { redirect_to @tenancy, notice: "Tenancy was successfully created." }
        format.json { render :show, status: :created, location: @tenancy }
      end
    else
      if result.failure.code == :not_found
        head :not_found
      else
        @tenancy = (result.failure.data && result.failure.data[:tenancy]) || Tenancy.new(tenancy_create_params)
        respond_to do |format|
          format.html { render :new, status: :unprocessable_content }
          format.json { render json: @tenancy.errors, status: :unprocessable_content }
        end
      end
    end
  end

  def update
    result = Tenancies::UpdateService.call(
      tenancy: @tenancy,
      attributes: tenancy_update_params
    )

    if result.success?
      @tenancy = result.value!.data[:tenancy]
      respond_to do |format|
        format.html { redirect_to @tenancy, notice: "Tenancy was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @tenancy }
      end
    else
      respond_to do |format|
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @tenancy.errors, status: :unprocessable_content }
      end
    end
  end

  def destroy
    if @tenancy.destroy
      respond_to do |format|
        format.html { redirect_to tenancies_path, notice: "Tenancy was successfully destroyed.", status: :see_other }
        format.json { head :no_content }
      end
    else
      respond_to do |format|
        format.html { redirect_to @tenancy, alert: @tenancy.errors.full_messages.to_sentence.presence || "Cannot delete tenancy with financial history. Terminate the tenancy instead.", status: :see_other }
        format.json { render json: @tenancy.errors, status: :unprocessable_content }
      end
    end
  end

  private

    def set_tenancy
      @tenancy = authenticated_user.tenancies.includes(
        { rentable_unit: :property },
        { tenancy_parties: :party },
        :rent_terms
      ).find(params.expect(:id))
    end

    # The exports carry whichever view and period the page is showing, so a
    # shared statement URL and its download stay the same document.
    def statement_pdf
      Tenancies::StatementPdfService.call(
        tenancy: @tenancy,
        date_range: @date_range,
        statement: @view_mode == "all" ? nil : @statement,
        activity_rows: @view_mode == "all" ? @financial_activity : nil
      )
    end

    def statement_csv
      Tenancies::StatementCsvService.call(
        tenancy: @tenancy,
        date_range: @date_range,
        statement: @view_mode == "all" ? nil : @statement,
        activity_rows: @view_mode == "all" ? @financial_activity : nil
      )
    end

    # A range the page refuses to report on is not a document either: send the
    # reader back to the page that can explain why.
    def statement_export_blocked?
      return false if @date_range.valid?

      redirect_to statement_tenancy_path(@tenancy),
                  alert: "Unable to generate financial report: #{@date_range.errors.to_sentence.presence || 'the From date cannot be after the Through date'}. Adjust the dates and download again."
      true
    end

    def statement_export_filename(extension)
      scope = @view_mode == "all" ? "tenancy-financial-activity" : "tenant-account-statement"
      period = if (year = @date_range.year)
        year.to_s
      else
        from = @date_range.from
        through = @date_range.through || Date.current
        [ from ? from.iso8601 : "opening", through.iso8601 ].join("-to-")
      end

      "#{scope}-#{@tenancy.rentable_unit.display_name.parameterize}-#{period}.#{extension}"
    end

    def set_form_data
      user = authenticated_user
      @properties = user.properties.includes(:rentable_units).order(:address)
      @parties = user.parties.order(:display_name)
    end

    def tenancy_create_params
      params.require(:tenancy).permit(
        :rentable_unit_id,
        :agreement_type,
        :commencement_date,
        :termination_date,
        :late_period_days
      )
    end

    def tenancy_update_params
      params.require(:tenancy).permit(
        :agreement_type,
        :termination_date,
        :late_period_days
      )
    end

    def participants_params
      if params[:tenancy][:participants].present?
        params[:tenancy][:participants].map do |p|
          {
            party_id: p[:party_id],
            role: p[:role],
            effective_from: p[:effective_from],
            effective_until: p[:effective_until]
          }
        end
      elsif (pids = params[:tenancy][:party_ids]).present?
        pids.to_a.filter_map do |party_id|
          next if party_id.blank?
          { party_id: party_id, role: "tenant" }
        end
      else
        []
      end
    end

    def initial_rent_params
      if params[:tenancy][:initial_rent].present?
        params[:tenancy][:initial_rent].permit(
          :amount_cents,
          :due_day,
          :frequency,
          :effective_from,
          :effective_until
        )
      else
        rent_cents = if params[:tenancy][:rent_amount_cents].present?
          params[:tenancy][:rent_amount_cents].to_i
        elsif params[:tenancy][:rent_amount].present?
          (params[:tenancy][:rent_amount].to_f * 100).round
        end

        {
          amount_cents: rent_cents,
          due_day: params[:tenancy][:due_day] || 1,
          frequency: params[:tenancy][:frequency] || "monthly",
          effective_from: params[:tenancy][:commencement_date]
        }
      end
    end
end
