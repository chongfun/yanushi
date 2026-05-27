class TenantsController < ApplicationController
  before_action :set_tenant, only: %i[ show edit update destroy ]

  def index
    @tenants = Current.session.user.tenants
  end


  def show
  end


  def new
    @tenant = Tenant.new
  end


  def edit
  end

  def create
    @tenant = Tenant.new(tenant_params)
    @tenant.user = Current.session.user

    respond_to do |format|
      if @tenant.save
        format.html { redirect_to @tenant, notice: "Tenant was successfully created." }
        format.json { render :show, status: :created, location: @tenant }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @tenant.errors, status: :unprocessable_content }
      end
    end
  end


  def update
    respond_to do |format|
      if @tenant.update(tenant_params)
        format.html { redirect_to @tenant, notice: "Tenant was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @tenant }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @tenant.errors, status: :unprocessable_content }
      end
    end
  end


  def destroy
    @tenant.destroy!

    respond_to do |format|
      format.html { redirect_to tenants_path, notice: "Tenant was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_tenant
      @tenant = Current.session.user.tenants.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def tenant_params
      params.require(:tenant).permit(:name, :mailing_address, :phone_number, :email_address, tenant_aliases_attributes: [ :id, :alias_name, :_destroy ])
    end
end
