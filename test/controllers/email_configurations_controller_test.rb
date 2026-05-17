require "test_helper"

class EmailConfigurationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
  end

  test "should get show (settings index)" do
    # When no configuration exists, it should still render or build one
    get email_configuration_url
    assert_response :success
  end

  test "should get edit" do
    # Create configuration first
    @user.create_email_configuration!(
      gmail_address: "kyle@example.com",
      google_refresh_token: "refresh",
      google_access_token: "access",
      google_token_expires_at: Time.current + 1.hour
    )

    get edit_email_configuration_url
    assert_response :success
  end

  test "should update/create email configuration" do
    @user.create_email_configuration!(
      gmail_address: "kyle@example.com",
      google_refresh_token: "refresh",
      google_access_token: "access",
      google_token_expires_at: Time.current + 1.hour,
      enabled: true
    )

    patch email_configuration_url, params: {
      email_configuration: {
        enabled: "0"
      }
    }

    assert_redirected_to email_configuration_url
    assert_not @user.reload.email_configuration.enabled?
  end

  test "should trigger email ingestion" do
    # Create configuration
    @config = @user.create_email_configuration!(
      gmail_address: "kyle@example.com",
      google_refresh_token: "refresh",
      google_access_token: "access",
      google_token_expires_at: Time.current + 1.hour,
      enabled: true
    )

    post ingest_email_configuration_url
    assert_redirected_to email_configuration_url
    assert_equal "Payment email ingestion has been started.", flash[:notice]
  end
end
