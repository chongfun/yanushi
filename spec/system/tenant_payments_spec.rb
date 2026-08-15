require "rails_helper"

RSpec.describe "TenantPayments", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Payment Ave") }
  let!(:unit) { create(:rentable_unit, property: property) }
  let!(:party) { create(:party, user: user, display_name: "Ledger Tester") }
  let!(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.today, late_period_days: 5) }

  before do
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: Date.today)
    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "records a tenant payment and verifies PDF receipt link" do
    visit tenant_payments_path

    click_on "New Payment"

    select "#{property.address} - Tenancy ##{tenancy.id} (#{party.display_name})", from: "Tenancy / Property / Tenants"
    fill_in "Payment date", with: Date.today.to_s
    fill_in "Amount", with: "1000"
    fill_in "Payment method", with: "Check"

    click_on "Create Tenant payment"

    expect(page).to have_text("Payment was successfully created")
    expect(page).to have_link("Download PDF Receipt")
  end
end
