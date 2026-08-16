require "rails_helper"

RSpec.describe Properties::FinancialItemsQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "returns all yearly financial item types sorted by date" do
    charge = create(:charge, :other_charge, tenancy: tenancy, charge_date: Date.new(2026, 5, 1), amount_cents: 100_000)
    receipt = create(:receipt, tenancy: tenancy, received_on: Date.new(2026, 5, 5), amount_cents: 100_000)
    expense = create(:expense, property: property, expense_date: Date.new(2026, 5, 10), amount: 50)
    reimburse_charge = create(:charge, :reimbursement_charge, tenancy: tenancy, source_expense: expense, charge_date: Date.new(2026, 5, 10), amount_cents: 5000)
    create(:expense, property: property, expense_date: Date.new(2025, 5, 10), amount: 30)

    items = described_class.new(property: property).call(year: 2026)

    expect(items.map { |item| item[:object] }).to eq([ charge, receipt, reimburse_charge, expense ])
    expect(items.map { |item| item[:type] }).to eq([ "Charge", "Payment", "Charge", "Expense" ])
  end
end
