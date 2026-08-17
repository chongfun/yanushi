require "rails_helper"

RSpec.describe Expenses::CreateService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }

  it "creates an expense and posts to ledger atomically" do
    expect {
      result = described_class.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 4, 15),
        amount_cents: 25_000,
        vendor_name: "Fix-It Fast",
        external_reference: "INV-999",
        description: "Repaired front door lock"
      )
      expect(result).to be_success
      expense = result.value!.data[:expense]
      expect(expense).to be_posted
      expect(expense.amount_cents).to eq(25_000)
      expect(expense.vendor_name).to eq("Fix-It Fast")
    }.to change(Expense, :count).by(1)
     .and change(JournalEntry, :count).by(1)
     .and change(Posting, :count).by(2)
  end

  it "supports decimal string amount parsing" do
    result = described_class.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.current,
      amount: "150.50"
    )
    expect(result).to be_success
    expect(result.value!.data[:expense].amount_cents).to eq(15_050)
  end

  it "rejects invalid amounts (negative, zero, fractional cents, garbage)" do
    res1 = described_class.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount: "-10")
    expect(res1).to be_failure

    res2 = described_class.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount: "0")
    expect(res2).to be_failure

    res3 = described_class.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount: "100.005")
    expect(res3).to be_failure

    res4 = described_class.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount: "abc")
    expect(res4).to be_failure
  end

  it "rejects non-integer amount_cents" do
    expect(described_class.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount_cents: "100")).to be_failure
    expect(described_class.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount_cents: "100oops")).to be_failure
    expect(described_class.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount_cents: -500)).to be_failure
  end

  it "rejects property mismatch when rentable unit belongs to different property" do
    other_prop = create(:property, user: user)
    foreign_unit = create(:rentable_unit, property: other_prop)

    result = described_class.call(
      property: property,
      rentable_unit: foreign_unit,
      expense_kind: "repairs",
      paid_on: Date.current,
      amount_cents: 10_000
    )
    expect(result).to be_failure
    expect(result.failure.code).to eq(:property_mismatch)
  end

  it "rolls back expense creation if ledger posting fails" do
    allow(Expenses::PostService).to receive(:call).and_return(ServiceResult.failure(error: "Posting error", code: :posting_error))

    expect {
      result = described_class.call(
        property: property,
        expense_kind: "utilities",
        paid_on: Date.current,
        amount_cents: 10_000
      )
      expect(result).to be_failure
    }.not_to change(Expense, :count)
  end

  it "rejects missing property, category, or invalid paid_on date" do
    expect(described_class.call(property: nil, expense_kind: "utilities", paid_on: Date.current, amount_cents: 10_000)).to be_failure
    expect(described_class.call(property: property, expense_kind: nil, paid_on: Date.current, amount_cents: 10_000)).to be_failure
    expect(described_class.call(property: property, expense_kind: "utilities", paid_on: nil, amount_cents: 10_000)).to be_failure
    expect(described_class.call(property: property, expense_kind: "utilities", paid_on: "invalid-date", amount_cents: 10_000)).to be_failure
    expect(described_class.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount_cents: -500)).to be_failure
  end
end
