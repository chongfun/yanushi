require "rails_helper"

RSpec.describe "Double-Entry Accounting Milestone 8 Invariants", type: :model do
  let(:user) { create(:user) }
  let(:property_a) { create(:property, user: user, address: "Property A") }
  let(:property_b) { create(:property, user: user, address: "Property B") }
  let(:unit_a1) { create(:rentable_unit, property: property_a, name: "Unit A1") }
  let(:unit_a2) { create(:rentable_unit, property: property_a, name: "Unit A2") }
  let(:unit_b1) { create(:rentable_unit, property: property_b, name: "Unit B1") }

  let(:tenancy_a1) { create(:tenancy, rentable_unit: unit_a1, agreement_type: "month_to_month", commencement_date: Date.new(2026, 1, 1), termination_date: nil) }
  let(:tenancy_a2) { create(:tenancy, rentable_unit: unit_a2, agreement_type: "month_to_month", commencement_date: Date.new(2026, 1, 1), termination_date: nil) }
  let(:tenancy_b1) { create(:tenancy, rentable_unit: unit_b1, agreement_type: "month_to_month", commencement_date: Date.new(2026, 1, 1), termination_date: nil) }

  let!(:rent_term_a1) { create(:rent_term, tenancy: tenancy_a1, amount_cents: 200_000, effective_from: Date.new(2026, 1, 1), effective_until: nil) }
  let!(:rent_term_a2) { create(:rent_term, tenancy: tenancy_a2, amount_cents: 150_000, effective_from: Date.new(2026, 1, 1), effective_until: nil) }
  let!(:rent_term_b1) { create(:rent_term, tenancy: tenancy_b1, amount_cents: 300_000, effective_from: Date.new(2026, 1, 1), effective_until: nil) }

  let(:party_a1) { create(:party, user: user) }
  let(:party_a2) { create(:party, user: user) }
  let(:party_b1) { create(:party, user: user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  it "guarantees property summary matches direct SQL posting sums for cash, income, and expenses" do
    # Create charges and receipts on Unit A1
    Charges::CreateService.call(
      tenancy: tenancy_a1,
      charge_kind: "rent",
      amount_cents: 200_000,
      charge_date: Date.new(2026, 1, 1)
    )
    Receipts::CreateService.call(
      tenancy: tenancy_a1,
      payer_party: party_a1,
      amount_cents: 200_000,
      received_on: Date.new(2026, 1, 5),
      payment_method: "check"
    )

    # Create charges and partial receipts on Unit A2
    Charges::CreateService.call(
      tenancy: tenancy_a2,
      charge_kind: "rent",
      amount_cents: 150_000,
      charge_date: Date.new(2026, 1, 1)
    )
    Receipts::CreateService.call(
      tenancy: tenancy_a2,
      payer_party: party_a2,
      amount_cents: 100_000,
      received_on: Date.new(2026, 1, 5),
      payment_method: "check"
    )

    # Create property-wide expense and unit-scoped expense on Property A
    Expenses::CreateService.call(
      property: property_a,
      expense_kind: "repairs",
      amount_cents: 40_000,
      paid_on: Date.new(2026, 1, 10)
    )
    Expenses::CreateService.call(
      property: property_a,
      rentable_unit: unit_a1,
      expense_kind: "cleaning_and_maintenance",
      amount_cents: 15_000,
      paid_on: Date.new(2026, 1, 15)
    )

    # Activity on Property B (should be isolated from Property A)
    Charges::CreateService.call(
      tenancy: tenancy_b1,
      charge_kind: "rent",
      amount_cents: 300_000,
      charge_date: Date.new(2026, 1, 1)
    )
    Receipts::CreateService.call(
      tenancy: tenancy_b1,
      payer_party: party_b1,
      amount_cents: 300_000,
      received_on: Date.new(2026, 1, 5),
      payment_method: "check"
    )
    Expenses::CreateService.call(
      property: property_b,
      expense_kind: "insurance",
      amount_cents: 80_000,
      paid_on: Date.new(2026, 1, 10)
    )

    summary_a = Accounting::PropertySummaryQuery.call(property: property_a, year: 2026)

    # Direct SQL assertions for Property A
    cash_account = user.accounts.find_by(key: "cash")
    expected_net_cash = cash_account.postings.joins(:journal_entry)
                                    .where(property_id: property_a.id)
                                    .where("journal_entries.occurred_on BETWEEN ? AND ?", Date.new(2026, 1, 1), Date.new(2026, 12, 31))
                                    .sum(:amount_cents)

    expect(summary_a.net_cash_movement_cents).to eq(expected_net_cash)
    expect(summary_a.net_cash_movement_cents).to eq(245_000) # $300,000 cash in - $55,000 cash out
    expect(summary_a.income_recognized_cents).to eq(350_000) # $2,000 + $1,500
    expect(summary_a.operating_expenses_cents).to eq(55_000)
    expect(summary_a.tenant_receivable_cents).to eq(50_000) # $150 rent - $100 paid on Unit A2

    # Property B isolation
    summary_b = Accounting::PropertySummaryQuery.call(property: property_b, year: 2026)
    expect(summary_b.net_cash_movement_cents).to eq(220_000) # $300,000 cash in - $80,000 cash out
    expect(summary_b.operating_expenses_cents).to eq(80_000)
  end

  it "preserves chronological running balance across charges, payments, and corrections" do
    charge_res = Charges::CreateService.call(
      tenancy: tenancy_a1,
      charge_kind: "rent",
      amount_cents: 200_000,
      charge_date: Date.new(2026, 1, 1)
    )
    charge = charge_res.value!.data[:charge]

    Receipts::CreateService.call(
      tenancy: tenancy_a1,
      payer_party: party_a1,
      amount_cents: 120_000,
      received_on: Date.new(2026, 1, 5),
      payment_method: "check"
    )

    # Correct the original rent charge from $2,000 to $1,800 on Jan 10
    Charges::CorrectService.call(
      charge: charge,
      amount_cents: 180_000,
      charge_date: Date.new(2026, 1, 1)
    )

    statement = Accounting::TenantReceivableActivityQuery.call(tenancy: tenancy_a1, year: 2026)

    # 4 entries in statement:
    # 1. Original Charge ($2,000) -> running balance: $2,000 (marked corrected)
    # 2. Reversal (-$2,000) -> running balance: $0
    # 3. Replacement Charge ($1,800) -> running balance: $1,800
    # 4. Payment (-$1,200) -> running balance: $600
    expect(statement.closing_balance_cents).to eq(60_000) # $1,800 - $1,200 = $600
    expect(statement.closing_balance).to eq(BigDecimal("600.00"))
  end
end
