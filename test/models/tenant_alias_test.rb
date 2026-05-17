require "test_helper"

class TenantAliasTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:one) # Using tenant fixture
  end

  test "validates presence of name" do
    tenant_alias = TenantAlias.new(tenant: @tenant)
    assert_not tenant_alias.valid?
    assert_includes tenant_alias.errors[:name], "can't be blank"
  end

  test "validates uniqueness of name scoped to tenant" do
    # Create first alias
    TenantAlias.create!(tenant: @tenant, name: "Katie Page")

    # Try duplicate alias
    duplicate = TenantAlias.new(tenant: @tenant, name: "Katie Page")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "allows same name alias for different tenants" do
    tenant_two = tenants(:two)
    TenantAlias.create!(tenant: @tenant, name: "Katie Page")

    different_tenant_alias = TenantAlias.new(tenant: tenant_two, name: "Katie Page")
    assert different_tenant_alias.valid?
  end
end
