require "rails_helper"

RSpec.describe Expenses::PostService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }

  it "posts double-entry Dr Expense / Cr Cash for property-wide expense" do
    expense = create(:expense,
      property: property,
      rentable_unit: nil,
      expense_kind: "utilities",
      amount_cents: 30_000,
      paid_on: Date.new(2026, 5, 10)
    )

    result = described_class.call(expense: expense)
    expect(result).to be_success

    entry = result.value!.data[:journal_entry]
    expect(entry.source).to eq(expense)
    expect(entry.event_type).to eq("expense_posted")
    expect(entry.occurred_on).to eq(Date.new(2026, 5, 10))
    expect(entry.postings.count).to eq(2)

    dr_posting = entry.postings.find { |p| p.amount_cents.positive? }
    cr_posting = entry.postings.find { |p| p.amount_cents.negative? }

    expect(dr_posting.account.key).to eq("expense_utilities")
    expect(dr_posting.amount_cents).to eq(30_000)
    expect(dr_posting.property).to eq(property)
    expect(dr_posting.rentable_unit).to be_nil

    expect(cr_posting.account.key).to eq("cash")
    expect(cr_posting.amount_cents).to eq(-30_000)
    expect(cr_posting.property).to eq(property)
    expect(cr_posting.rentable_unit).to be_nil
  end

  it "posts double-entry Dr Expense / Cr Cash with unit dimensions for unit-scoped expense" do
    expense = create(:expense,
      property: property,
      rentable_unit: unit,
      expense_kind: "repairs",
      amount_cents: 50_000,
      paid_on: Date.new(2026, 6, 1)
    )

    result = described_class.call(expense: expense)
    expect(result).to be_success

    entry = result.value!.data[:journal_entry]
    dr_posting = entry.postings.find { |p| p.amount_cents.positive? }
    cr_posting = entry.postings.find { |p| p.amount_cents.negative? }

    expect(dr_posting.account.key).to eq("expense_repairs")
    expect(dr_posting.amount_cents).to eq(50_000)
    expect(dr_posting.property).to eq(property)
    expect(dr_posting.rentable_unit).to eq(unit)

    expect(cr_posting.account.key).to eq("cash")
    expect(cr_posting.amount_cents).to eq(-50_000)
    expect(cr_posting.property).to eq(property)
    expect(cr_posting.rentable_unit).to eq(unit)
  end

  it "returns failure when expense is missing or invalid" do
    result = described_class.call(expense: nil)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:invalid_input)

    # Missing owner
    unowned_exp = build(:expense, property: nil)
    res2 = described_class.call(expense: unowned_exp)
    expect(res2).to be_failure
    expect(res2.failure.code).to eq(:invalid_input)

    # Unknown expense kind
    invalid_kind_exp = build(:expense, property: property, expense_kind: "non_existent")
    res3 = described_class.call(expense: invalid_kind_exp)
    expect(res3).to be_failure
    expect(res3.failure.code).to eq(:invalid_expense_kind)
  end
end
