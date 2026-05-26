require 'rails_helper'

RSpec.describe "RentalProperties", type: :system do
  let!(:user) { create(:user) }

  before do
    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "creates a rental property successfully" do
    visit rental_properties_path
    click_on "New rental property"

    fill_in "Address", with: "123 Main St"
    select "Single Family Residence", from: "Property type"
    fill_in "Square footage", with: "1500"

    click_on "Create Rental property"

    expect(page).to have_text("Rental property was successfully created")
    expect(page).to have_text("123 Main St")
  end

  it "filters the financial ledger by year" do
    rental_property = create(:rental_property, user: user, address: "999 Ledger St")
    lease = create(:lease, rental_property: rental_property, commencement_date: Date.current)
    create(:scheduled_rent, lease: lease, due_date: Date.current, amount: 1000.0)

    past_year = Date.current.year - 1

    # Create an expense in the past year
    create(:expense,
      rental_property: rental_property,
      category: "repairs",
      amount: 50.00,
      expense_date: Date.new(past_year, 5, 15),
      description: "Past year plumbing"
    )

    visit rental_property_path(rental_property)

    # We should see the current year's scheduled rent, but not the past year's expense
    expect(page).to have_text("Scheduled Rent")
    expect(page).not_to have_text("Past year plumbing")

    # Manually visit the filtered URL (auto-submit won't fire in RackTest)
    visit rental_property_path(rental_property, year: past_year)

    # We should now see the past year's expense, and NOT the current year's scheduled rent
    expect(page).to have_text("Past year plumbing")
    expect(page).not_to have_text("Scheduled Rent")
  end
end
