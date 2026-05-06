require "application_system_test_case"

class RentPaymentsTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @property = RentalProperty.create!(user: @user, address: "999 Payment Ave", property_type: "single_family_residence", square_footage: 1000)
    @lease = Lease.create!(rental_property: @property, lease_type: "month_to_month", commencement_date: Date.today, annual_rental_amount: 12000, late_period_days: 5)
    @scheduled_rent = @lease.scheduled_rents.first

    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "recording a rent payment and downloading a receipt" do
    visit rent_payments_path

    click_on "New rent payment"

    select @scheduled_rent.display_name, from: "Scheduled rent"
    fill_in "Payment date", with: Date.today.to_s
    fill_in "Amount", with: "1000"
    fill_in "Payment method", with: "Check"

    click_on "Create Rent payment"

    assert_text "Rent payment was successfully created"

    # Check that PDF receipt link exists
    assert_selector "a", text: "Download PDF Receipt"
  end
end
