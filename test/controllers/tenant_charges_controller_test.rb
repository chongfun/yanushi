require "test_helper"

class TenantChargesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @tenant_charge = tenant_charges(:one)
  end

  test "should show tenant_charge" do
    get tenant_charge_url(@tenant_charge)
    assert_response :success
  end

  test "should destroy tenant_charge" do
    assert_difference("TenantCharge.count", -1) do
      delete tenant_charge_url(@tenant_charge)
    end

    assert_redirected_to expenses_url
  end
end
