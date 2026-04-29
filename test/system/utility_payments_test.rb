require "application_system_test_case"

class UtilityPaymentsTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @property = RentalProperty.create!(user: @user, address: "999 Utility Ave", property_type: "residential", square_footage: 1000)
    @tenant = Tenant.create!(user: @user, name: "Utility Tester", mailing_address: "123 Test", phone_number: "555-5555", email_address: "tester@example.com")
    
    # Log in
    visit new_session_path
    fill_in "email_address", with: @user.email_address
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "creating a utility payment" do
    visit utility_payments_path
    
    click_on "New utility payment"

    select @tenant.name, from: "Tenant"
    select @property.address, from: "Rental property"
    fill_in "Amount", with: "150.50"
    fill_in "Payment date", with: Date.today.to_s

    click_on "Create Utility payment"

    assert_text "Utility payment was successfully created"
    assert_text "150.5"
  end
end
