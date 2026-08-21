require "rails_helper"

RSpec.describe "Dashboards", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Dashboard Ave") }
  let!(:unit) { create(:rentable_unit, property: property) }
  let!(:expense) { create(:expense, property: property, category: "repairs", amount: 250.00, expense_date: Date.today, description: "Fix door") }
  let!(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.today, late_period_days: 5) }
  let!(:payment) { create(:receipt, tenancy: tenancy, amount_cents: 100_000, received_on: Date.today, payment_method: "cash") }

  before do
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "summarizes income and expenses on the dashboard" do
    visit root_path

    expect(page).to have_text("Dashboard")
    expect(page).to have_text("999 Dashboard Ave")

    expect(page).to have_text("Total Income")
    expect(page).to have_text("$1,000.00")

    expect(page).to have_text("Total Expenses")
    expect(page).to have_text("$250.00")

    expect(page).to have_text("Net Income")
    expect(page).to have_text("$750.00")
  end
end
