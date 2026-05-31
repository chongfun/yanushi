module PaymentIngestions
  class FormDataQuery
    Result = Data.define(:tenants, :leases, :tenant_leases_map, :lease_tenants_map)

    def initialize(user:)
      @user = user
    end

    def call
      Result.new(
        tenants: user.tenants.order(:name),
        leases: leases,
        tenant_leases_map: tenant_leases_map,
        lease_tenants_map: lease_tenants_map
      )
    end

    private

    attr_reader :user

    def leases
      Lease.joins(:tenants).where(tenants: { user_id: user.id }).includes(:rental_property).distinct
    end

    def tenant_leases_map
      map = Hash.new { |hash, key| hash[key] = [] }
      LeaseTenant.joins(:tenant).where(tenants: { user_id: user.id }).pluck(:tenant_id, :lease_id).each do |tenant_id, lease_id|
        map[tenant_id] << lease_id
      end
      map
    end

    def lease_tenants_map
      map = Hash.new { |hash, key| hash[key] = [] }
      LeaseTenant.joins(lease: :rental_property).where(rental_properties: { user_id: user.id }).pluck(:lease_id, :tenant_id).each do |lease_id, tenant_id|
        map[lease_id] << tenant_id
      end
      map
    end
  end
end
