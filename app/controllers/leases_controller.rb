class LeasesController < ApplicationController
  before_action :set_lease, only: %i[ show edit update destroy generate_scheduled_rents ]
  before_action :set_form_data, only: %i[ new edit create update ]

  def index
    @leases = authenticated_user.leases.includes(:rental_property, :tenants)
  end


  def show
  end


  def new
    @lease = Lease.new
  end


  def edit
  end


  def create
    permitted_params = lease_params

    @lease = Lease.new(permitted_params)

    respond_to do |format|
      result = Leases::SaveService.call(lease: @lease, sync_scheduled_rents: true, previously_new_record: true)
      if result.success?
        format.html { redirect_to @lease, notice: "Lease was successfully created." }
        format.json { render :show, status: :created, location: @lease }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @lease.errors, status: :unprocessable_content }
      end
    end
  end


  def update
    permitted_params = lease_params
    @lease.assign_attributes(permitted_params)

    respond_to do |format|
      result = Leases::SaveService.call(lease: @lease)
      if result.success?
        format.html { redirect_to @lease, notice: "Lease was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @lease }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @lease.errors, status: :unprocessable_content }
      end
    end
  end


  def destroy
    @lease.destroy!

    respond_to do |format|
      format.html { redirect_to leases_path, notice: "Lease was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end


  def generate_scheduled_rents
    year = params[:year].presence || Date.current.year
    ScheduledRentsGenerator.new(@lease, year).call
    redirect_to @lease.rental_property, notice: "Scheduled rents for #{year} have been generated."
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_lease
      @lease = authenticated_user.leases.find(params.expect(:id))
    end

    def set_form_data
      user = authenticated_user
      @rental_properties = user.rental_properties.order(:address)
      @tenants = user.tenants.order(:name)
    end

    # Only allow a list of trusted parameters through.
    def lease_params
      permitted_params = params.expect(lease: [ :rental_property_id, :lease_type, :commencement_date, :termination_date, :annual_rental_amount, :late_period_days, :security_deposit, tenant_ids: Array.new ])

      user = authenticated_user
      if permitted_params[:rental_property_id].present?
        raise ActiveRecord::RecordNotFound unless user.rental_properties.where(id: permitted_params[:rental_property_id]).exists?
      end

      # @type var tenant_ids: Array[String]
      tenant_ids = Array(permitted_params[:tenant_ids])
      tenant_ids = tenant_ids.reject { |tenant_id| tenant_id.blank? }
      if tenant_ids.any?
        raise ActiveRecord::RecordNotFound unless user.tenants.where(id: tenant_ids).count == tenant_ids.count
      end

      permitted_params
    end
end
