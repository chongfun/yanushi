require "application_system_test_case"

class SessionsTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
  end

  test "unsuccessful login shows toast notification" do
    visit new_session_path

    fill_in "email", with: "wrong@example.com"
    fill_in "password", with: "wrongpassword"
    click_on "Sign in"

    # Verify that the toast notification appears
    assert_selector ".toast", text: "Try another email address or password."
    assert_selector ".alert-error"
  end

  test "successful login redirects appropriately" do
    visit new_session_path

    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"

    # Successful login redirects (to root by default, or after_authentication_url)
    # The default generated Rails code doesn't set a notice on successful login
    assert_current_path root_path
  end
end
