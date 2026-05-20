require "test_helper"

class TenantAliasTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:one) # assuming tenants fixture exists
  end

  test "should be valid with alias_name and tenant" do
    tenant_alias = TenantAlias.new(tenant: @tenant, alias_name: "Sam S")
    assert tenant_alias.valid?
  end

  test "should be invalid without alias_name" do
    tenant_alias = TenantAlias.new(tenant: @tenant, alias_name: nil)
    assert_not tenant_alias.valid?
    assert_includes tenant_alias.errors[:alias_name], "can't be blank"
  end

  test "should enforce case-insensitive uniqueness on alias_name scoped to tenant" do
    TenantAlias.create!(tenant: @tenant, alias_name: "Sam S")

    # Same tenant, duplicate name -> invalid
    duplicate_same_tenant = TenantAlias.new(tenant: @tenant, alias_name: "sam s")
    assert_not duplicate_same_tenant.valid?
    assert_includes duplicate_same_tenant.errors[:alias_name], "has already been taken"

    # Different tenant, same name -> valid
    duplicate_diff_tenant = TenantAlias.new(tenant: tenants(:two), alias_name: "sam s")
    assert duplicate_diff_tenant.valid?
  end

  test "should strip whitespace from alias_name" do
    tenant_alias = TenantAlias.create!(tenant: @tenant, alias_name: "   Sam S   ")
    assert_equal "Sam S", tenant_alias.alias_name
  end
end
