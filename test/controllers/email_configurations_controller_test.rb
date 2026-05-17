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
      imap_server: "imap.example.com",
      imap_port: 993,
      username: "kyle",
      password: "password"
    )

    get edit_email_configuration_url
    assert_response :success
  end

  test "should update/create email configuration" do
    assert_difference -> { EmailConfiguration.count } => 1 do
      patch email_configuration_url, params: {
        email_configuration: {
          imap_server: "imap.gmail.com",
          imap_port: 993,
          username: "gmail-user",
          password: "gmail-password",
          mailbox: "INBOX",
          ssl: "1",
          enabled: "1"
        }
      }
    end

    assert_redirected_to email_configuration_url
    assert_equal "gmail-user", @user.reload.email_configuration.username
  end

  test "should trigger email ingestion" do
    # Create configuration
    @config = @user.create_email_configuration!(
      imap_server: "imap.example.com",
      imap_port: 993,
      username: "kyle",
      password: "password",
      enabled: true
    )

    post ingest_email_configuration_url
    assert_redirected_to email_configuration_url
    assert_equal "Payment email ingestion has been started.", flash[:notice]
  end
end
