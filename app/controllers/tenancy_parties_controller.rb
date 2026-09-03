class TenancyPartiesController < ApplicationController
  before_action :set_tenancy
  before_action :set_tenancy_party, only: %i[edit update destroy]

  def new
    @tenancy_party = @tenancy.tenancy_parties.new(
      effective_from: @tenancy.commencement_date || Date.current,
      effective_until: @tenancy.termination_date,
      role: "tenant"
    )
    @parties = authenticated_user.parties.order(:display_name)
  end

  def edit
    @parties = authenticated_user.parties.order(:display_name)
  end

  def create
    result = TenancyParties::CreateService.call(
      tenancy: @tenancy,
      user: authenticated_user,
      params: tenancy_party_params
    )

    if result.success?
      @tenancy_party = result.value!.data[:tenancy_party]
      respond_to do |format|
        format.html { redirect_to tenancy_agreement_path(@tenancy), notice: "Participant was successfully added." }
        format.json { render json: @tenancy_party, status: :created }
      end
    else
      @tenancy_party = (result.failure.data && result.failure.data[:tenancy_party]) || @tenancy.tenancy_parties.new(tenancy_party_params.to_h)
      @parties = authenticated_user.parties.order(:display_name)
      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @tenancy_party.errors, status: :unprocessable_content }
      end
    end
  end

  def update
    result = TenancyParties::UpdateService.call(
      tenancy_party: @tenancy_party,
      attributes: tenancy_party_params
    )

    if result.success?
      @tenancy_party = result.value!.data[:tenancy_party]
      respond_to do |format|
        format.html { redirect_to tenancy_agreement_path(@tenancy), notice: "Participant was successfully updated.", status: :see_other }
        format.json { render json: @tenancy_party, status: :ok }
      end
    else
      @parties = authenticated_user.parties.order(:display_name)
      respond_to do |format|
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @tenancy_party.errors, status: :unprocessable_content }
      end
    end
  end

  def destroy
    result = TenancyParties::DestroyService.call(tenancy_party: @tenancy_party)

    if result.success?
      respond_to do |format|
        format.html { redirect_to tenancy_agreement_path(@tenancy), notice: "Participant was successfully removed.", status: :see_other }
        format.json { head :no_content }
      end
    else
      respond_to do |format|
        format.html { redirect_to tenancy_agreement_path(@tenancy), alert: result.failure.error, status: :see_other }
        format.json { render json: { error: result.failure.error }, status: :unprocessable_content }
      end
    end
  end

  private

  def set_tenancy
    @tenancy = authenticated_user.tenancies.find(params.expect(:tenancy_id))
  end

  def set_tenancy_party
    @tenancy_party = @tenancy.tenancy_parties.find(params.expect(:id))
  end

  def tenancy_party_params
    params.require(:tenancy_party).permit(:party_id, :role, :effective_from, :effective_until).to_h.symbolize_keys
  end
end
