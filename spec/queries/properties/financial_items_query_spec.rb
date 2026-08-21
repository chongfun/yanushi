require "rails_helper"

RSpec.describe Properties::FinancialItemsQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "returns all yearly financial item types sorted by date" do
    scheduled_rent = create(:scheduled_rent, tenancy: tenancy, due_date: Date.new(2026, 5, 1), amount: 1000)
    tenant_payment = create(:tenant_payment, tenancy: tenancy, payment_date: Date.new(2026, 5, 5), amount: 1000)
    expense = create(:expense, property: property, expense_date: Date.new(2026, 5, 10), amount: 50)
    tenant_charge = create(:tenant_charge, tenancy: tenancy, expense: expense, charge_date: Date.new(2026, 5, 10), amount: 50)
    create(:expense, property: property, expense_date: Date.new(2025, 5, 10), amount: 30)

    items = described_class.new(property: property).call(year: 2026)

    expect(items.map { |item| item[:object] }).to eq([ scheduled_rent, tenant_payment, tenant_charge, expense ])
    expect(items.map { |item| item[:type] }).to eq([ "Scheduled Rent", "Tenant Payment", "Tenant Charge", "Expense" ])
  end
end
