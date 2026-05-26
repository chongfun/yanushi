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
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)
    other_tenant = Tenant.create!(user: other_user, name: "Other Tenant")
    other_lease = Lease.create!(
      rental_property: other_property,
      commencement_date: Date.current,
      annual_rental_amount: 12000,
      lease_type: :term
    )
    LeaseTenant.create!(lease: other_lease, tenant: other_tenant)

    get new_tenant_payment_url

    assert_response :success
    assert_no_match other_property.address, response.body
    assert_no_match other_tenant.name, response.body
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

  test "should not create tenant payment with other user's lease" do
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)
    other_lease = Lease.create!(rental_property: other_property, commencement_date: Date.current - 1.day, annual_rental_amount: 12000, lease_type: :term)

    assert_no_difference("TenantPayment.count") do
      post tenant_payments_url, params: { tenant_payment: { lease_id: other_lease.id, amount: 500, payment_date: Date.current, payment_method: "Zelle", transaction_number: "TXNTEST456" } }
      assert_response :not_found
    end
  end

  test "should not update tenant payment to other user's lease" do
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)
    other_lease = Lease.create!(rental_property: other_property, commencement_date: Date.current - 1.day, annual_rental_amount: 12000, lease_type: :term)

    patch tenant_payment_url(@tenant_payment), params: { tenant_payment: { lease_id: other_lease.id } }
    assert_response :not_found
  end
end
