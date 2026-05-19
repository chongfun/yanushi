require "application_system_test_case"

class TenantsTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "creating a tenant" do
    visit tenants_path
    click_on "New tenant"

    fill_in "Primary Legal Name", with: "Jane Doe"
    fill_in "Mailing Address", with: "456 Side St"
    fill_in "Phone Number", with: "555-1234"
    fill_in "Email Address", with: "jane@example.com"

    click_on "Create Tenant"

    assert_text "Tenant was successfully created"
    assert_text "Jane Doe"
  end
end
