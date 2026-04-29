require "application_system_test_case"

class LeasesTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    # Ensure a property and tenant exist for the select boxes
    @property = RentalProperty.create!(user: @user, address: "999 Lease Ave", property_type: "residential", square_footage: 1000)
    @tenant = Tenant.create!(user: @user, name: "Lease Tester", mailing_address: "123 Test", phone_number: "555-5555", email_address: "tester@example.com")
    
    # Log in
    visit new_session_path
    fill_in "email_address", with: @user.email_address
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "creating a month-to-month lease generates 12 months of scheduled rents" do
    visit leases_path
    
    click_on "New lease"

    select @property.address, from: "Rental property"
    # Select tenant (we will use a multi-select or checkboxes, assume select for now)
    select @tenant.name, from: "Tenants"
    
    select "Month to month", from: "Lease type"
    fill_in "Commencement date", with: Date.today.to_s
    fill_in "Annual rental amount", with: "12000"
    fill_in "Late period days", with: 5

    click_on "Create Lease"

    assert_text "Lease was successfully created"
    
    # Verify Scheduled Rents were created
    lease = Lease.last
    assert_equal 12, lease.scheduled_rents.count
    assert_equal 1000.0, lease.scheduled_rents.first.expected_amount # 12000 / 12
  end
end
