require "test_helper"

class TenantPaymentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @lease = leases(:one)
    @tenant_payment = tenant_payments(:one)
  end

  test "should get index" do
    get tenant_payments_url
    assert_response :success
  end

  test "should get new" do
    get new_tenant_payment_url
    assert_response :success
  end

  test "should create tenant_payment" do
    assert_difference("TenantPayment.count") do
      post tenant_payments_url, params: { tenant_payment: { lease_id: @lease.id, amount: 500, payment_date: Date.current, payment_method: "Zelle", transaction_number: "TXNTEST123" } }
    end

    assert_redirected_to tenant_payment_url(TenantPayment.last)
  end

  test "should show tenant_payment" do
    get tenant_payment_url(@tenant_payment)
    assert_response :success
  end

  test "should get pdf receipt" do
    get tenant_payment_url(@tenant_payment, format: :pdf)
    assert_response :success
    assert_equal "application/pdf", response.content_type
  end

  test "should get edit" do
    get edit_tenant_payment_url(@tenant_payment)
    assert_response :success
  end

  test "should update tenant_payment" do
    patch tenant_payment_url(@tenant_payment), params: { tenant_payment: { amount: 600 } }
    assert_redirected_to tenant_payment_url(@tenant_payment)
  end

  test "should destroy tenant_payment" do
    assert_difference("TenantPayment.count", -1) do
      delete tenant_payment_url(@tenant_payment)
    end

    assert_redirected_to tenant_payments_url
  end
end
