class TenantChargesController < ApplicationController
  before_action :set_tenant_charge, only: %i[ show destroy ]

  # GET /tenant_charges/1 or /tenant_charges/1.json
  def show
  end

  # DELETE /tenant_charges/1 or /tenant_charges/1.json
  def destroy
    @tenant_charge.destroy!

    respond_to do |format|
      format.html { redirect_to expenses_path, notice: "Tenant charge was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_tenant_charge
      @tenant_charge = Current.session.user.tenant_charges.find(params.expect(:id))
    end
end
