require "test_helper"

class LeaseTenantTest < ActiveSupport::TestCase
  test "requires tenant to belong to the same user as the lease" do
    other_tenant = Tenant.create!(user: users(:two), name: "Other Tenant")
    lease_tenant = LeaseTenant.new(lease: leases(:one), tenant: other_tenant)

    assert_not lease_tenant.valid?
    assert_includes lease_tenant.errors[:tenant], "must belong to the same user as the lease"
  end
end
