require "rails_helper"

RSpec.describe "Tenancies", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Lease Ave") }
  let!(:unit) { create(:rentable_unit, property: property, name: "Main Unit") }
  let!(:party) { create(:party, user: user, display_name: "Lease Tester") }

  before do
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "creates a month-to-month tenancy and displays its details" do
    visit tenancies_path

    click_on "New Tenancy"

    select unit.name, from: "Select Rentable Unit"
    check party.display_name

    select "Month To Month", from: "Agreement Type"
    fill_in "Commencement Date", with: Date.today.to_s
    fill_in "Monthly Rent ($)", with: "1000"
    fill_in "Grace Period (Days)", with: "5"

    click_on "Create Tenancy"

    expect(page).to have_text("Tenancy was successfully created")
    expect(page).to have_text("Lease Tester")
    expect(page).to have_text("$1,000.00")
  end
end
