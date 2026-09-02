require "rails_helper"

RSpec.describe "Money", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "742 Evergreen Terrace") }
  let!(:unit) { create(:rentable_unit, property: property, name: "Unit 1") }
  let!(:party) { create(:party, user: user, display_name: "Homer Simpson") }
  let!(:tenancy) { create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2025, 1, 1)) }
  let!(:rent_term) { create(:rent_term, tenancy: tenancy, amount_cents: 120_000, effective_from: Date.new(2025, 1, 1)) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant")

    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "displays cross-portfolio financial activity and supports property and year filtering", :js do
    # Record payment
    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 120_000,
      received_on: Date.new(2025, 6, 1),
      payment_method: "check"
    )

    # Record expense
    Expenses::CreateService.call(
      property: property,
      expense_kind: "repairs",
      amount_cents: 45_000,
      paid_on: Date.new(2025, 7, 15),
      vendor_name: "Ace Plumbing",
      description: "Sink repair"
    )

    visit money_path

    expect(page).to have_text("Money")
    expect(page).to have_link("Activity")
    expect(page).to have_link("Receipts")
    expect(page).to have_link("Expenses")

    # Select year 2025
    select "2025", from: "ma-year"
    click_on "Apply"

    expect(page).to have_text("742 Evergreen Terrace")
    expect(page).to have_text("Payment")
    expect(page).to have_text("Sink repair")
    expect(page).to have_text("1,200.00")
    expect(page).to have_text("450.00")

    # Filter by property
    select "742 Evergreen Terrace", from: "ma-property"
    click_on "Apply"

    expect(page).to have_text("742 Evergreen Terrace")

    # Navigate to Receipts tab
    click_on "Receipts"
    expect(page).to have_text("Homer Simpson")
    expect(page).to have_text("$1,200.00")
    expect(page).to have_text("Check")

    # Navigate to Expenses tab
    click_on "Expenses"
    expect(page).to have_text("Ace Plumbing")
    expect(page).to have_text("Repairs")
    expect(page).to have_text("$450.00")

    # Click on Expense row to view expense details
    click_on "Ace Plumbing"
    expect(page).to have_text("Expense Details")
    expect(page).to have_text("Sink repair")
    expect(page).to have_text("$450.00")
    expect(page).to have_link("742 Evergreen Terrace")

    # Navigate from Expense to Property Workspace -> Activity tab
    click_on "742 Evergreen Terrace"
    expect(page).to have_text("Units")
    click_on "Activity"
    expect(page).to have_css(".yn-tab[aria-current='page']", text: "Activity", wait: 5)
    expect(page).to have_current_path(property_activity_path(property))

    select "2025", from: "pa-year"
    click_on "Apply"
    expect(page).to have_text("Sink repair")

    # Click on Journal link to inspect double-entry ledger postings
    within("tr", text: "Sink repair") do
      click_link "Journal"
    end
    expect(page).to have_text("Journal Entry")
    expect(page).to have_text("Repairs")
    expect(page).to have_text("$450.00")
  end
end
