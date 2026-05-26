require 'rails_helper'

RSpec.describe "Leases", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:rental_property, user: user, address: "999 Lease Ave") }
  let!(:tenant) { create(:tenant, user: user, name: "Lease Tester") }

  before do
    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "creates a month-to-month lease and generates 12 months of scheduled rents" do
    visit leases_path

    click_on "New lease"

    select property.address, from: "Rental property"
    select tenant.name, from: "Tenants"

    select "Month to month", from: "Lease type"
    fill_in "Commencement date", with: Date.today.to_s
    fill_in "Annual rental amount", with: "12000"
    fill_in "Late period days", with: "5"
    fill_in "Security deposit", with: "500"

    click_on "Create Lease"

    expect(page).to have_text("Lease was successfully created")
    expect(page).to have_text("500.0")

    # Verify Scheduled Rents were created
    lease = Lease.last
    expect(lease.scheduled_rents.count).to eq(12)
    expect(lease.scheduled_rents.first.amount.to_f).to eq(1000.0) # 12000 / 12
  end
end
