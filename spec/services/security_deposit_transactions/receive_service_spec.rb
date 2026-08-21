require "rails_helper"

RSpec.describe SecurityDepositTransactions::ReceiveService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  it "records a deposit receipt, posts double-entry journal entry, and updates held liability" do
    result = described_class.call(
      security_deposit: security_deposit,
      party: party,
      amount: "1500.00",
      occurred_on: Date.current,
      memo: "First installment",
      external_reference: "CHK1001"
    )

    expect(result).to be_success
    txn = result.value!.data[:transaction]
    expect(txn.amount_cents).to eq(150_000)
    expect(txn).to be_posted
    expect(txn).to be_received
    expect(txn.external_reference).to eq("CHK1001")
    expect(security_deposit.held_cents).to eq(150_000)
    expect(tenancy.current_balance_cents).to eq(0) # Receivable unchanged!
  end

  it "accepts numeric amount, integer cents, string date, and party_id" do
    res = described_class.call(
      security_deposit: security_deposit,
      party_id: party.id,
      amount: 1000,
      occurred_on: "2026-01-01"
    )
    expect(res).to be_success
    expect(res.value!.data[:transaction].amount_cents).to eq(100_000)

    res2 = described_class.call(
      security_deposit: security_deposit,
      party: party,
      amount_cents: 50_000,
      occurred_on: Date.current
    )
    expect(res2).to be_success
    expect(res2.value!.data[:transaction].amount_cents).to eq(50_000)
  end

  it "rejects string amount_cents" do
    res = described_class.call(
      security_deposit: security_deposit,
      party: party,
      amount_cents: "50000",
      occurred_on: Date.current
    )
    expect(res).to be_failure
    expect(res.failure.code).to eq(:invalid_input)
  end

  it "rejects future occurred_on or invalid party" do
    res1 = described_class.call(
      security_deposit: security_deposit,
      party: party,
      amount: "1000.00",
      occurred_on: Date.tomorrow
    )
    expect(res1).to be_failure
    expect(res1.failure.code).to eq(:invalid_date)

    other_user = create(:user)
    other_party = create(:party, user: other_user)
    res2 = described_class.call(
      security_deposit: security_deposit,
      party: other_party,
      amount: "1000.00",
      occurred_on: Date.current
    )
    expect(res2).to be_failure
    expect(res2.failure.code).to eq(:party_user_mismatch)
  end

  it "rejects invalid amount, unpersisted deposit, unpersisted party, or missing occurred_on" do
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "-10", occurred_on: Date.current).failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "invalid", occurred_on: Date.current).failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: nil, amount_cents: nil, occurred_on: Date.current).failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "100", occurred_on: nil).failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "100", occurred_on: "").failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "100", occurred_on: "bad-date").failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: SecurityDeposit.new, party: party, amount: "100", occurred_on: Date.current).failure.code).to eq(:invalid_deposit)
    expect(described_class.call(security_deposit: security_deposit, party: Party.new, amount: "100", occurred_on: Date.current).failure.code).to eq(:invalid_party)
  end

  it "handles posting failure gracefully" do
    allow(Accounting::PostEntryService).to receive(:call).and_return(
      ServiceResult.failure(error: "Posting error", code: :post_failed)
    )
    res = described_class.call(security_deposit: security_deposit, party: party, amount: "100", occurred_on: Date.current)
    expect(res).to be_failure
    expect(res.failure.code).to eq(:post_failed)
  end

  it "accepts memo and rejects non-existent party_id" do
    res1 = described_class.call(
      security_deposit: security_deposit,
      party: party,
      amount_cents: 10_000,
      occurred_on: Date.current,
      memo: "check payment"
    )
    expect(res1).to be_success
    expect(res1.value!.data[:transaction].memo).to eq("check payment")

    res2 = described_class.call(
      security_deposit: security_deposit,
      party_id: 999_999,
      amount_cents: 10_000,
      occurred_on: Date.current
    )
    expect(res2).to be_failure
    expect(res2.failure.code).to eq(:invalid_party)
  end
end
