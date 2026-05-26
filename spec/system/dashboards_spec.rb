require 'rails_helper'

RSpec.describe "Dashboards", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:rental_property, user: user, address: "999 Dashboard Ave") }
  let!(:expense) { create(:expense, rental_property: property, category: "repairs", amount: 250.00, expense_date: Date.today, description: "Fix door") }
  let!(:lease) { create(:lease, rental_property: property, lease_type: "month_to_month", commencement_date: Date.today, annual_rental_amount: 12000, late_period_days: 5) }
  let!(:payment) { create(:tenant_payment, lease: lease, amount: 1000.0, payment_date: Date.today, payment_method: "cash") }

  before do
    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "summarizes income and expenses on the dashboard" do
    visit root_path

    expect(page).to have_text("Dashboard")
    expect(page).to have_text("999 Dashboard Ave")

    # Verify Income is displayed
    expect(page).to have_text("Total Income")
    expect(page).to have_text("$1,000.00")

    # Verify Expenses are displayed
    expect(page).to have_text("Total Expenses")
    expect(page).to have_text("$250.00")

    # Verify Net Income
    expect(page).to have_text("Net Income")
    expect(page).to have_text("$750.00")
  end
end
