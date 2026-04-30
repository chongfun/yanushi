require "test_helper"

class RentPaymentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @rent_payment = rent_payments(:one)
  end

  test "should get index" do
    get rent_payments_url
    assert_response :success
  end

  test "should get new" do
    get new_rent_payment_url
    assert_response :success
  end

  test "should create rent_payment" do
    assert_difference("RentPayment.count") do
      post rent_payments_url, params: { rent_payment: { amount: @rent_payment.amount, payment_date: @rent_payment.payment_date, payment_method: @rent_payment.payment_method, scheduled_rent_id: @rent_payment.scheduled_rent_id, transaction_number: @rent_payment.transaction_number } }
    end

    assert_redirected_to rent_payment_url(RentPayment.last)
  end

  test "should show rent_payment" do
    get rent_payment_url(@rent_payment)
    assert_response :success
  end

  test "should get edit" do
    get edit_rent_payment_url(@rent_payment)
    assert_response :success
  end

  test "should update rent_payment" do
    patch rent_payment_url(@rent_payment), params: { rent_payment: { amount: @rent_payment.amount, payment_date: @rent_payment.payment_date, payment_method: @rent_payment.payment_method, scheduled_rent_id: @rent_payment.scheduled_rent_id, transaction_number: @rent_payment.transaction_number } }
    assert_redirected_to rent_payment_url(@rent_payment)
  end

  test "should destroy " do
    assert_difference("RentPayment.count", -1) do
      delete rent_payment_url(@rent_payment)
    end

    assert_redirected_to rent_payments_url
  end
end
