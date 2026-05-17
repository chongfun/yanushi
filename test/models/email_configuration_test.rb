require "test_helper"

class EmailConfigurationTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "validates gmail_address, google_refresh_token, and google_access_token" do
    config = EmailConfiguration.new(user: @user)
    assert_not config.valid?
    assert_includes config.errors[:gmail_address], "can't be blank"
    assert_includes config.errors[:google_refresh_token], "can't be blank"
    assert_includes config.errors[:google_access_token], "can't be blank"
  end

  test "encrypts google_refresh_token and google_access_token" do
    config = EmailConfiguration.create!(
      user: @user,
      gmail_address: "kyle@workspace.com",
      google_refresh_token: "secret_refresh",
      google_access_token: "secret_access",
      google_token_expires_at: Time.current + 1.hour
    )

    config.reload
    assert_equal "secret_refresh", config.google_refresh_token
    assert_equal "secret_access", config.google_access_token

    raw_refresh = ActiveRecord::Base.connection.select_value(
      "SELECT google_refresh_token FROM email_configurations WHERE id = #{config.id}"
    )
    raw_access = ActiveRecord::Base.connection.select_value(
      "SELECT google_access_token FROM email_configurations WHERE id = #{config.id}"
    )

    assert_not_equal "secret_refresh", raw_refresh
    assert_not_equal "secret_access", raw_access
  end
end
