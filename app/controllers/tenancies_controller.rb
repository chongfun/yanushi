class TenanciesController < ApplicationController
  before_action :set_tenancy, only: %i[show edit update destroy statement]
  before_action :set_form_data, only: %i[new edit create update]

  def index
    @tenancies = authenticated_user.tenancies.includes({ rentable_unit: :property }, { tenancy_parties: :party })
  end

  def show
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
