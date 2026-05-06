require "application_system_test_case"

class DashboardsTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @property = RentalProperty.create!(user: @user, address: "999 Dashboard Ave", property_type: "single_family_residence", square_footage: 1000)

    # Create some expense and payment data
    Expense.create!(rental_property: @property, category: "repairs", amount: 250.00, expense_date: Date.today, description: "Fix door")

    @lease = Lease.create!(rental_property: @property, lease_type: "month_to_month", commencement_date: Date.today, annual_rental_amount: 12000, late_period_days: 5)
    scheduled = @lease.scheduled_rents.first
    RentPayment.create!(scheduled_rent: scheduled, amount: 1000.0, payment_date: Date.today, payment_method: "cash")

    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "viewing the dashboard summarizes income and expenses" do
    visit root_path

    assert_text "Dashboard"
    assert_text "999 Dashboard Ave"

    # Verify Income is displayed (1000 rent payment)
    assert_text "Total Income"
    assert_text "$1,000.00"

    # Verify Expenses are displayed (250 repair)
    assert_text "Total Expenses"
    assert_text "$250.00"

    # Verify Net Income
    assert_text "Net Income"
    assert_text "$750.00"
  end
end
