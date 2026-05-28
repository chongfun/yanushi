require "rails_helper"

RSpec.describe Leases::BalanceQuery do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }

  it "computes credits, debits, and balance as of a date" do
    create(:scheduled_rent, lease: lease, amount: 1000, due_date: Date.new(2026, 1, 1))
    expense = create(:expense, rental_property: property, amount: 200, expense_date: Date.new(2026, 1, 2))
    create(:tenant_charge, lease: lease, expense: expense, amount: 200, charge_date: Date.new(2026, 1, 2))
    create(:tenant_payment, lease: lease, amount: 900, payment_date: Date.new(2026, 1, 3))

    query = described_class.new(lease: lease)

    expect(query.total_credits(as_of: Date.new(2026, 1, 3))).to eq(900)
    expect(query.total_debits(as_of: Date.new(2026, 1, 3))).to eq(1200)
    expect(query.balance_as_of(Date.new(2026, 1, 3))).to eq(-300)
  end
end
