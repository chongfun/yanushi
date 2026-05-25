require "test_helper"

class TenantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @tenant = tenants(:one)
  end

  test "should get index" do
    get tenants_url
    assert_response :success
  end

  test "should get new" do
    get new_tenant_url
    assert_response :success
  end

  test "should create tenant" do
    assert_difference("Tenant.count") do
      post tenants_url, params: { tenant: { email_address: @tenant.email_address, mailing_address: @tenant.mailing_address, name: @tenant.name, phone_number: @tenant.phone_number } }
    end

    assert_redirected_to tenant_url(Tenant.last)
  end

  test "should show tenant" do
    get tenant_url(@tenant)
    assert_response :success
  end

  test "should get edit" do
    get edit_tenant_url(@tenant)
    assert_response :success
  end

  test "should update tenant" do
    patch tenant_url(@tenant), params: { tenant: { email_address: @tenant.email_address, mailing_address: @tenant.mailing_address, name: @tenant.name, phone_number: @tenant.phone_number } }
    assert_redirected_to tenant_url(@tenant)
  end

  test "should create tenant with nested aliases" do
    assert_difference("Tenant.count", 1) do
      assert_difference("TenantAlias.count", 2) do
        post tenants_url, params: {
          tenant: {
            name: "Alicia Keys",
            email_address: "alicia@example.com",
            tenant_aliases_attributes: [
              { alias_name: "Ali Keys" },
              { alias_name: "@alicia" }
            ]
          }
        }
      end
    end
    assert_redirected_to tenant_url(Tenant.last)
  end

  test "should update tenant and nested aliases (add, destroy)" do
    # Create tenant with alias first
    tenant = Tenant.create!(user: users(:one), name: "Alicia Keys", email_address: "alicia@example.com")
    alias1 = TenantAlias.create!(tenant: tenant, alias_name: "Ali Keys")

    # Update: edit existing, add new, destroy existing
    assert_difference("TenantAlias.count", 0) do # 1 added, 1 destroyed -> diff is 0
      patch tenant_url(tenant), params: {
        tenant: {
          tenant_aliases_attributes: {
            "0" => { id: alias1.id, alias_name: "Ali Keys", _destroy: "1" },
            "1" => { alias_name: "New Alias" }
          }
        }
      }
    end

    assert_redirected_to tenant_url(tenant)
    assert_not tenant.tenant_aliases.exists?(id: alias1.id)
    assert tenant.tenant_aliases.exists?(alias_name: "New Alias")
  end

  test "should destroy" do
    assert_difference("Tenant.count", -1) do
      delete tenant_url(@tenant)
    end

    assert_redirected_to tenants_url
  end
end
