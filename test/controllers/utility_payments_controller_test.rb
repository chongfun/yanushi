require "test_helper"

class UtilityPaymentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @utility_payment = utility_payments(:one)
  end

  test "should get index" do
    get utility_payments_url
    assert_response :success
  end

  test "should get new" do
    get new_utility_payment_url
    assert_response :success
  end

  test "should create utility_payment" do
    assert_difference("UtilityPayment.count") do
      post utility_payments_url, params: { utility_payment: { amount: @utility_payment.amount, payment_date: @utility_payment.payment_date, lease_id: @utility_payment.lease_id } }
    end

    assert_redirected_to utility_payment_url(UtilityPayment.last)
  end

  test "should show utility_payment" do
    get utility_payment_url(@utility_payment)
    assert_response :success
  end

  test "should get edit" do
    get edit_utility_payment_url(@utility_payment)
    assert_response :success
  end

  test "should update utility_payment" do
    patch utility_payment_url(@utility_payment), params: { utility_payment: { amount: @utility_payment.amount, payment_date: @utility_payment.payment_date, lease_id: @utility_payment.lease_id } }
    assert_redirected_to utility_payment_url(@utility_payment)
  end

  test "should destroy " do
    assert_difference("UtilityPayment.count", -1) do
      delete utility_payment_url(@utility_payment)
    end

    assert_redirected_to utility_payments_url
  end
end
