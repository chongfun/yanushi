require 'rails_helper'

RSpec.describe "TenantPayments", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:rental_property, user: user, address: "999 Payment Ave") }
  let!(:tenant) { create(:tenant, user: user, name: "Ledger Tester") }
  let!(:lease) { create(:lease, rental_property: property, lease_type: "month_to_month", commencement_date: Date.today, annual_rental_amount: 12000, late_period_days: 5) }

  before do
    lease.tenants << tenant
    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "records a tenant payment and verifies PDF receipt link" do
    visit tenant_payments_path

    click_on "New Payment"

    select "#{property.address} - Lease ##{lease.id} (#{tenant.name})", from: "Lease / Property / Tenants"
    fill_in "Payment date", with: Date.today.to_s
    fill_in "Amount", with: "1000"
    fill_in "Payment method", with: "Check"

    click_on "Create Tenant payment"

    expect(page).to have_text("Payment was successfully created")
    expect(page).to have_link("Download PDF Receipt")
  end
end
