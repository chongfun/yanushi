require "rails_helper"

RSpec.describe "Milestone 6 Acceptance: Double-Entry Security Deposits", type: :feature do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  it "verifies full Milestone 6 end-to-end security deposit lifecycle and accounting invariants" do
    # 1. Set up contractual deposit requirement
    create_deposit_res = SecurityDeposits::CreateService.call(
      tenancy: tenancy,
      required_amount: "2000.00",
      due_on: Date.new(2026, 1, 1)
    )
    expect(create_deposit_res).to be_success
    deposit = create_deposit_res.value!.data[:security_deposit]

    # Verify initial balances
    expect(deposit.held_cents).to eq(0)
    expect(tenancy.current_balance_cents).to eq(0)

    # 2. Receive $2,000 refundable deposit
    receive_res = SecurityDepositTransactions::ReceiveService.call(
      security_deposit: deposit,
      party: party,
      amount: "2000.00",
      occurred_on: Date.new(2026, 1, 1),
      memo: "Initial security deposit"
    )
    expect(receive_res).to be_success
    expect(deposit.held_cents).to eq(200_000)
    expect(tenancy.current_balance_cents).to eq(0) # Receivable unaffected!

    # Schedule E summary should have 0 rents received
    schedule_e = property.schedule_e_summary(year: 2026)
    expect(schedule_e.rents_received).to eq(0)

    # 3. Refund $500
    refund_res = SecurityDepositTransactions::RefundService.call(
      security_deposit: deposit,
      party: party,
      amount: "500.00",
      occurred_on: Date.new(2026, 1, 15),
      memo: "Partial refund"
    )
    expect(refund_res).to be_success
    expect(deposit.held_cents).to eq(150_000)
    expect(tenancy.current_balance_cents).to eq(0)

    # 4. Create a $500 damage reimbursement charge
    charge_res = Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "other",
      amount_cents: 50_000,
      charge_date: Date.new(2026, 2, 1),
      due_on: Date.new(2026, 2, 1),
      description: "Drywall damage repair"
    )
    expect(charge_res).to be_success
    charge = charge_res.value!.data[:charge]
    expect(tenancy.current_balance_cents).to eq(50_000)

    # 5. Apply $500 deposit toward the charge
    apply_res = SecurityDepositTransactions::ApplyService.call(
      security_deposit: deposit,
      charge: charge,
      amount: "500.00",
      occurred_on: Date.new(2026, 2, 5),
      memo: "Apply deposit for drywall repair"
    )
    expect(apply_res).to be_success
    app_txn = apply_res.value!.data[:transaction]

    # Verify balances after application
    expect(deposit.held_cents).to eq(100_000)
    expect(tenancy.current_balance_cents).to eq(0) # Receivable settled!

    # 6. Verify Charge cannot be voided or corrected while deposit application is active
    void_charge_res = Charges::VoidService.call(charge: charge)
    expect(void_charge_res).to be_failure
    expect(void_charge_res.failure.code).to eq(:active_deposit_applications)

    correct_charge_res = Charges::CorrectService.call(charge: charge, amount_cents: 60_000)
    expect(correct_charge_res).to be_failure
    expect(correct_charge_res.failure.code).to eq(:active_deposit_applications)

    # 7. Void deposit application -> restores receivable and held liability, unblocks charge lifecycle
    void_app_res = SecurityDepositTransactions::VoidService.call(transaction: app_txn)
    expect(void_app_res).to be_success
    expect(deposit.held_cents).to eq(150_000)
    expect(tenancy.current_balance_cents).to eq(50_000)

    # Now charge can be voided
    void_charge_res2 = Charges::VoidService.call(charge: charge)
    expect(void_charge_res2).to be_success
    expect(tenancy.current_balance_cents).to eq(0)
  end
end
