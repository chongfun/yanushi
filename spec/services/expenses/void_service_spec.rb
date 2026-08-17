require "rails_helper"

RSpec.describe Expenses::VoidService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "voids an active expense and reverses its journal entry at original paid_on date" do
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.new(2026, 3, 10),
      amount_cents: 30_000
    )
    expense = create_res.value!.data[:expense]
    original_entry = create_res.value!.data[:journal_entry]

    expect {
      result = described_class.call(expense: expense)
      expect(result).to be_success
    }.to change(JournalEntry, :count).by(1)

    expect(expense.reload).to be_voided

    reversal_entry = JournalEntry.find_by(reversal_of_id: original_entry.id)
    expect(reversal_entry).to be_present
    expect(reversal_entry.occurred_on).to eq(Date.new(2026, 3, 10))

    # Net effect on accounts is zero
    dr_reversal = reversal_entry.postings.find { |p| p.amount_cents.positive? }
    cr_reversal = reversal_entry.postings.find { |p| p.amount_cents.negative? }

    expect(dr_reversal.account.key).to eq("cash")
    expect(dr_reversal.amount_cents).to eq(30_000)
    expect(cr_reversal.account.key).to eq("expense_utilities")
    expect(cr_reversal.amount_cents).to eq(-30_000)
  end

  it "rejects voiding an expense when active reimbursement charges exist" do
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.current,
      amount_cents: 30_000
    )
    expense = create_res.value!.data[:expense]

    charge_res = Charges::CreateReimbursementService.call(
      expense: expense,
      tenancy: tenancy,
      amount_cents: 15_000
    )
    expect(charge_res).to be_success
    charge = charge_res.value!.data[:charge]

    # Voiding expense fails while active charge exists
    result = described_class.call(expense: expense)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:active_reimbursements)
    expect(result.failure.error).to include("Cannot void expense with active reimbursement charges")
    expect(expense.reload).not_to be_voided

    # Void the reimbursement charge first
    Charges::VoidService.call(charge: charge)

    # Now voiding expense succeeds
    void_res = described_class.call(expense: expense)
    expect(void_res).to be_success
    expect(expense.reload).to be_voided
  end

  it "is idempotent on repeated calls" do
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "repairs",
      paid_on: Date.current,
      amount_cents: 10_000
    )
    expense = create_res.value!.data[:expense]

    res1 = described_class.call(expense: expense)
    expect(res1).to be_success

    expect {
      res2 = described_class.call(expense: expense)
      expect(res2).to be_success
    }.not_to change(JournalEntry, :count)
  end

  it "enforces user ownership when user is provided" do
    other_user = create(:user)
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "repairs",
      paid_on: Date.current,
      amount_cents: 10_000
    )
    expense = create_res.value!.data[:expense]

    result = described_class.call(expense: expense, user: other_user)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:not_found)
  end

  it "handles missing expense and reversal failure" do
    expect(described_class.call(expense: nil)).to be_failure

    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "repairs",
      paid_on: Date.current,
      amount_cents: 10_000
    )
    expense = create_res.value!.data[:expense]

    allow(Accounting::ReverseEntryService).to receive(:call).and_return(
      ServiceResult.failure(error: "Reversal failed", code: :reversal_error)
    )

    res = described_class.call(expense: expense)
    expect(res).to be_failure
    expect(res.failure.code).to eq(:reversal_error)
  end
end
