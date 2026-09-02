require "rails_helper"

RSpec.describe "Dashboards", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Dashboard Ave") }
  let!(:unit) { create(:rentable_unit, property: property) }
  let!(:party) { create(:party, user: user, display_name: "John Tenant") }
  let!(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.current.beginning_of_year) }
  let!(:rent_term) { create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.current.beginning_of_year) }
  let!(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)

    Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "rent",
      amount_cents: 100_000,
      charge_date: Date.current
    )

    Expenses::CreateService.call(
      property: property,
      expense_kind: "repairs",
      amount_cents: 25_000,
      paid_on: Date.current,
      description: "Fix door"
    )

    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "summarizes portfolio state and renders actionable items on Overview" do
    visit root_path

    expect(page).to have_button("Sign out")
    expect(page).to have_text("Overview")
    expect(page).to have_text("999 Dashboard Ave")

    # Attention item for outstanding balance
    expect(page).to have_text("Needs attention")
    expect(page).to have_text("John Tenant owes $1,000.00")
    expect(page).to have_text("Open tenancy →")

    # Metrics
    expect(page).to have_text("Properties")
    expect(page).to have_text("Units occupied")
    expect(page).to have_text("Outstanding balances")
    expect(page).to have_text("Net income, YTD")
    expect(page).to have_text("$750.00")

    # Recent activity
    expect(page).to have_text("Recent activity")
    expect(page).to have_text("Expense")
    expect(page).to have_text("Rent · #{unit.name}")

    # Click property link
    within("[aria-labelledby='properties-heading']") do
      click_on "999 Dashboard Ave"
    end
    expect(page).to have_current_path(property_path(property))
    expect(page).to have_text("Units")
  end
end
