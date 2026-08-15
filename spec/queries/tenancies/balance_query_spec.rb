require "rails_helper"

RSpec.describe Tenancies::BalanceQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "computes credits, debits, and balance as of a date" do
    create(:scheduled_rent, tenancy: tenancy, amount: 1000, due_date: Date.new(2026, 1, 1))
    expense = create(:expense, property: property, amount: 200, expense_date: Date.new(2026, 1, 2))
    create(:tenant_charge, tenancy: tenancy, expense: expense, amount: 200, charge_date: Date.new(2026, 1, 2))
    create(:tenant_payment, tenancy: tenancy, amount: 900, payment_date: Date.new(2026, 1, 3))

    query = described_class.new(tenancy: tenancy)

    expect(query.total_credits(as_of: Date.new(2026, 1, 3))).to eq(900)
    expect(query.total_debits(as_of: Date.new(2026, 1, 3))).to eq(1200)
    expect(query.balance_as_of(Date.new(2026, 1, 3))).to eq(-300)
  end
end
