require "test_helper"

class PaymentEmailsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
    @payment_email = PaymentEmail.create!(
      user: @user,
      message_id: "msg-9999",
      sender_name: "John Doe",
      amount: 100.0,
      payment_date: Date.current,
      status: :pending
    )
  end

  test "should get index" do
    get payment_emails_url
    assert_response :success
  end

  test "should show payment email details" do
    get payment_email_url(@payment_email)
    assert_response :success
  end
end
