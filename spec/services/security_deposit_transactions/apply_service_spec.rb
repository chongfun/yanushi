require "rails_helper"

RSpec.describe SecurityDepositTransactions::ApplyService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }
  let!(:charge) do
    res = Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "other",
      amount_cents: 50_000,
      charge_date: Date.new(2026, 1, 1),
      due_on: Date.new(2026, 1, 1),
      description: "Damage repair"
    )
    res.value!.data[:charge]
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: security_deposit,
      party: party,
      amount: "2000.00",
      occurred_on: Date.new(2026, 1, 1)
    )
  end

  it "applies deposit to charge, reducing liability and tenant receivable without double income" do
    expect(tenancy.current_balance_cents).to eq(50_000)
    expect(security_deposit.held_cents).to eq(200_000)

    result = described_class.call(
      security_deposit: security_deposit,
      charge: charge,
      amount: "500.00",
      occurred_on: Date.new(2026, 1, 10),
      memo: "Applied to damage"
    )

    expect(result).to be_success
    txn = result.value!.data[:transaction]
    expect(txn.amount_cents).to eq(50_000)
    expect(txn).to be_applied
    expect(security_deposit.held_cents).to eq(150_000)
    expect(tenancy.current_balance_cents).to eq(0)
    expect(charge.deposit_applied_cents).to eq(50_000)
    expect(charge.remaining_deposit_application_cents).to eq(0)
  end

  it "accepts charge_id, numeric amount, integer cents, and string date" do
    c2 = Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "other",
      amount_cents: 50_000,
      charge_date: Date.new(2026, 1, 1),
      due_on: Date.new(2026, 1, 1)
    ).value!.data[:charge]

    res = described_class.call(
      security_deposit: security_deposit,
      charge_id: c2.id,
      amount: 250,
      occurred_on: "2026-01-12"
    )
    expect(res).to be_success
    expect(res.value!.data[:transaction].amount_cents).to eq(25_000)

    c3 = Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "other",
      amount_cents: 50_000,
      charge_date: Date.new(2026, 1, 1),
      due_on: Date.new(2026, 1, 1)
    ).value!.data[:charge]

    res3 = described_class.call(
      security_deposit: security_deposit,
      charge: c3,
      amount_cents: 15_000,
      occurred_on: Date.current
    )
    expect(res3).to be_success
    expect(res3.value!.data[:transaction].amount_cents).to eq(15_000)
  end

  it "rejects string amount_cents" do
    res = described_class.call(
      security_deposit: security_deposit,
      charge: charge,
      amount_cents: "15000",
      occurred_on: Date.current
    )
    expect(res).to be_failure
    expect(res.failure.code).to eq(:invalid_input)
  end

  it "rejects application exceeding charge remaining capacity" do
    result = described_class.call(
      security_deposit: security_deposit,
      charge: charge,
      amount: "600.00",
      occurred_on: Date.new(2026, 1, 10)
    )
    expect(result).to be_failure
    expect(result.failure.code).to eq(:exceeds_charge_capacity)
  end

  it "rejects application exceeding tenancy outstanding balance" do
    # Record payment of $300 so tenancy balance is only $200
    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 30_000,
      received_on: Date.new(2026, 1, 5),
      payment_method: "check"
    )
    expect(tenancy.current_balance_cents).to eq(20_000)

    result = described_class.call(
      security_deposit: security_deposit,
      charge: charge,
      amount: "300.00",
      occurred_on: Date.new(2026, 1, 10)
    )
    expect(result).to be_failure
    expect(result.failure.code).to eq(:exceeds_tenancy_balance)
  end

  it "rejects application dated before the charge date" do
    future_charge = Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "other",
      amount_cents: 50_000,
      charge_date: Date.new(2026, 1, 10),
      due_on: Date.new(2026, 1, 10),
      description: "Future repair"
    ).value!.data[:charge]

    early_res = described_class.call(
      security_deposit: security_deposit,
      charge: future_charge,
      amount: "200.00",
      occurred_on: Date.new(2026, 1, 5)
    )
    expect(early_res).to be_failure
    expect(early_res.failure.code).to eq(:precedes_charge_date)

    on_date_res = described_class.call(
      security_deposit: security_deposit,
      charge: future_charge,
      amount: "200.00",
      occurred_on: Date.new(2026, 1, 10)
    )
    expect(on_date_res).to be_success

    after_date_res = described_class.call(
      security_deposit: security_deposit,
      charge: future_charge,
      amount: "200.00",
      occurred_on: Date.new(2026, 1, 15)
    )
    expect(after_date_res).to be_success
  end

  it "rejects application to an inactive or cross-tenancy charge" do
    other_unit = create(:rentable_unit, property: property)
    other_tenancy = create(:tenancy, rentable_unit: other_unit)
    other_charge = create(:charge, :posted, tenancy: other_tenancy, amount_cents: 50_000, charge_date: Date.current)

    res1 = described_class.call(
      security_deposit: security_deposit,
      charge: other_charge,
      amount: "100.00",
      occurred_on: Date.current
    )
    expect(res1).to be_failure
    expect(res1.failure.code).to eq(:tenancy_mismatch)

    void_res = Charges::VoidService.call(charge: charge)
    expect(void_res).to be_success

    res2 = described_class.call(
      security_deposit: security_deposit,
      charge: charge,
      amount: "100.00",
      occurred_on: Date.current
    )
    expect(res2).to be_failure
    expect(res2.failure.code).to eq(:invalid_charge_state)
  end

  it "rejects future date, missing date, or invalid inputs" do
    expect(described_class.call(security_deposit: security_deposit, charge: charge, amount: "100", occurred_on: Date.tomorrow).failure.code).to eq(:invalid_date)
    expect(described_class.call(security_deposit: security_deposit, charge: charge, amount: "100", occurred_on: nil).failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, charge: charge, amount: "100", occurred_on: "").failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, charge: charge, amount: "100", occurred_on: "bad").failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: SecurityDeposit.new, charge: charge, amount: "100", occurred_on: Date.current).failure.code).to eq(:invalid_deposit)
    expect(described_class.call(security_deposit: security_deposit, charge: Charge.new, amount: "100", occurred_on: Date.current).failure.code).to eq(:invalid_charge)
    expect(described_class.call(security_deposit: security_deposit, charge: charge, amount: "-50", occurred_on: Date.current).failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, charge: charge, amount: nil, amount_cents: nil, occurred_on: Date.current).failure.code).to eq(:invalid_input)
  end

  it "handles posting failure gracefully" do
    allow(Accounting::PostEntryService).to receive(:call).and_return(
      ServiceResult.failure(error: "Posting error", code: :post_failed)
    )
    res = described_class.call(security_deposit: security_deposit, charge: charge, amount: "100", occurred_on: Date.current)
    expect(res).to be_failure
    expect(res.failure.code).to eq(:post_failed)
  end

  it "accepts memo and rejects non-existent charge_id" do
    res1 = described_class.call(
      security_deposit: security_deposit,
      charge: charge,
      amount_cents: 10_000,
      occurred_on: Date.current,
      memo: "DEP-APP-1"
    )
    expect(res1).to be_success
    expect(res1.value!.data[:transaction].memo).to eq("DEP-APP-1")

    res2 = described_class.call(
      security_deposit: security_deposit,
      charge_id: 999_999,
      amount_cents: 10_000,
      occurred_on: Date.current
    )
    expect(res2).to be_failure
    expect(res2.failure.code).to eq(:invalid_charge)
  end
end
