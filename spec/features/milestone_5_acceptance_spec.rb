require "rails_helper"

RSpec.describe "Milestone 5 Acceptance: Expenses and Reimbursements", type: :feature do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit_a) { create(:rentable_unit, property: property, name: "Unit A") }
  let(:unit_b) { create(:rentable_unit, property: property, name: "Unit B") }
  let(:tenancy_a) { create(:tenancy, rentable_unit: unit_a, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31)) }
  let(:tenancy_b) { create(:tenancy, rentable_unit: unit_b, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31)) }

  it "produces 1 expense, 2 charges, 3 balanced journal entries, and 6 postings with no duplicated or hidden expense" do
    # 1. Record $300 utility Expense
    expense_result = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.new(2026, 3, 1),
      amount_cents: 30_000,
      description: "Monthly building utility bill"
    )
    expect(expense_result).to be_success
    expense = expense_result.value!.data[:expense]

    # 2. Charge Tenancy A $150 reimbursement
    reimburse_a_result = Charges::CreateReimbursementService.call(
      expense: expense,
      tenancy: tenancy_a,
      amount_cents: 15_000,
      charge_date: Date.new(2026, 3, 2),
      description: "Utility reimbursement 50%"
    )
    expect(reimburse_a_result).to be_success
    charge_a = reimburse_a_result.value!.data[:charge]

    # 3. Charge Tenancy B $150 reimbursement
    reimburse_b_result = Charges::CreateReimbursementService.call(
      expense: expense,
      tenancy: tenancy_b,
      amount_cents: 15_000,
      charge_date: Date.new(2026, 3, 2),
      description: "Utility reimbursement 50%"
    )
    expect(reimburse_b_result).to be_success
    charge_b = reimburse_b_result.value!.data[:charge]

    # Done conditions verification:
    expect(Expense.count).to eq(1)
    expect(Charge.count).to eq(2)
    expect(JournalEntry.count).to eq(3)
    expect(Posting.count).to eq(6)

    # All three entries balance: sum of amounts for each entry == 0
    JournalEntry.find_each do |entry|
      expect(entry.postings.sum(:amount_cents)).to eq(0)
    end

    # Financial breakdown verification:
    cash_account = user.accounts.find_by!(key: "cash")
    utilities_account = user.accounts.find_by!(key: "expense_utilities")
    receivable_account = user.accounts.find_by!(key: "tenant_receivable")
    reimbursement_income_account = user.accounts.find_by!(key: "reimbursement_income")

    # Cash: -30000
    expect(Posting.where(account: cash_account).sum(:amount_cents)).to eq(-30_000)

    # Utilities Expense: +30000
    expect(Posting.where(account: utilities_account).sum(:amount_cents)).to eq(30_000)

    # Tenant Receivable: +15000 for A, +15000 for B
    expect(Posting.where(account: receivable_account, tenancy: tenancy_a).sum(:amount_cents)).to eq(15_000)
    expect(Posting.where(account: receivable_account, tenancy: tenancy_b).sum(:amount_cents)).to eq(15_000)

    # Reimbursement Income: -30000 (credit)
    expect(Posting.where(account: reimbursement_income_account).sum(:amount_cents)).to eq(-30_000)

    # Expense capacity is fully exhausted
    expect(expense.reload.remaining_reimbursable_cents).to eq(0)
    expect(expense.fully_reimbursed?).to be true

    # Third reimbursement must fail
    reimburse_c_result = Charges::CreateReimbursementService.call(
      expense: expense,
      tenancy: tenancy_a,
      amount_cents: 100
    )
    expect(reimburse_c_result).to be_failure
    expect(reimburse_c_result.failure.code).to eq(:exceeds_expense_amount)
  end
end
