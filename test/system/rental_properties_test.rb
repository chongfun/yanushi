require "application_system_test_case"

class RentalPropertiesTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "creating a rental property" do
    visit rental_properties_path
    click_on "New rental property"

    fill_in "Address", with: "123 Main St"
    select "Residential", from: "Property type"
    fill_in "Square footage", with: 1500

    click_on "Create Rental property"

    assert_text "Rental property was successfully created"
    assert_text "123 Main St"
  end
end
