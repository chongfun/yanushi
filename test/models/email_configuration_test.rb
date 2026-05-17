require "test_helper"

class EmailConfigurationTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "validates presence of imap_server, username, and password" do
    config = EmailConfiguration.new(user: @user)
    assert_not config.valid?
    assert_includes config.errors[:imap_server], "can't be blank"
    assert_includes config.errors[:username], "can't be blank"
    assert_includes config.errors[:password], "can't be blank"
  end

  test "validates imap_port is positive integer" do
    config = EmailConfiguration.new(user: @user, imap_server: "imap.gmail.com", username: "kyle", password: "password", imap_port: -5)
    assert_not config.valid?
    assert_includes config.errors[:imap_port], "must be greater than 0"
  end

  test "encrypts password" do
    config = EmailConfiguration.create!(
      user: @user,
      imap_server: "imap.gmail.com",
      username: "kyle",
      password: "secret_app_password"
    )

    # Reload from database to ensure encryption is active
    config.reload
    assert_equal "secret_app_password", config.password

    # Confirm ciphertext is not plain text in DB
    raw_db_value = ActiveRecord::Base.connection.select_value(
      "SELECT password FROM email_configurations WHERE id = #{config.id}"
    )
    assert_not_equal "secret_app_password", raw_db_value
  end
end
