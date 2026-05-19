require "application_system_test_case"

class TenantPaymentsTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @property = RentalProperty.create!(user: @user, address: "999 Payment Ave", property_type: "single_family_residence", square_footage: 1000)
    @tenant = Tenant.create!(user: @user, name: "Ledger Tester", email_address: "ledger@example.com", phone_number: "555-5555")
    @lease = Lease.create!(rental_property: @property, lease_type: "month_to_month", commencement_date: Date.today, annual_rental_amount: 12000, late_period_days: 5)
    @lease.tenants << @tenant

    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "recording a tenant payment and downloading a receipt" do
    visit tenant_payments_path

    click_on "New Payment"

    select "#{@property.address} - Lease ##{@lease.id} (#{@tenant.name})", from: "Lease / Property / Tenants"
    fill_in "Payment date", with: Date.today.to_s
    fill_in "Amount", with: "1000"
    fill_in "Payment method", with: "Check"

    click_on "Create Tenant payment"

    assert_text "Payment was successfully created"

    # Check that PDF receipt link exists
    assert_selector "a", text: "Download PDF Receipt"
  end
end
