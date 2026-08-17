require "rails_helper"

RSpec.describe "Properties", type: :system do
  let!(:user) { create(:user) }

  before do
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "creates a property successfully" do
    visit properties_path
    click_on "New Property"

    fill_in "Address", with: "123 Main St"
    select "Single Family", from: "Asset type"
    fill_in "Square footage", with: "1500"

    click_on "Create Property"

    expect(page).to have_text("Property was successfully created")
    expect(page).to have_text("123 Main St")
  end

  it "filters the financial ledger by year" do
    property = create(:property, user: user, address: "999 Ledger St")
    unit = create(:rentable_unit, property: property)
    tenancy = create(:tenancy, rentable_unit: unit, commencement_date: Date.current)
    create(:charge, :other_charge, tenancy: tenancy, charge_date: Date.current, amount_cents: 100_000, description: "Current Charge")

    past_year = Date.current.year - 1

    create(:expense, :posted,
      property: property,
      expense_kind: "repairs",
      amount_cents: 5000,
      paid_on: Date.new(past_year, 5, 15),
      description: "Past year plumbing"
    )

    visit property_path(property)

    expect(page).to have_text("Current Charge")
    expect(page).not_to have_text("Past year plumbing")

    visit property_path(property, year: past_year)

    expect(page).to have_text("Past year plumbing")
    expect(page).not_to have_text("Current Charge")
  end
end
