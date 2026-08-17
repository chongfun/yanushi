require "rails_helper"

RSpec.describe SecurityDepositTransactions::RefundService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: security_deposit,
      party: party,
      amount: "2000.00",
      occurred_on: Date.new(2026, 1, 1)
    )
  end

  it "refunds held deposit, reduces liability, and leaves tenancy receivable unchanged" do
    result = described_class.call(
      security_deposit: security_deposit,
      party: party,
      amount: "750.00",
      occurred_on: Date.new(2026, 1, 15),
      external_reference: "CHK500",
      memo: "Partial refund"
    )

    expect(result).to be_success
    txn = result.value!.data[:transaction]
    expect(txn.amount_cents).to eq(75_000)
    expect(txn).to be_posted
    expect(txn).to be_refunded
    expect(txn.external_reference).to eq("CHK500")
    expect(security_deposit.held_cents).to eq(125_000)
    expect(tenancy.current_balance_cents).to eq(0)
  end

  it "accepts party_id, numeric amount, integer cents, and string date" do
    res = described_class.call(
      security_deposit: security_deposit,
      party_id: party.id,
      amount: 250,
      occurred_on: "2026-01-20"
    )
    expect(res).to be_success
    expect(res.value!.data[:transaction].amount_cents).to eq(25_000)

    res2 = described_class.call(
      security_deposit: security_deposit,
      party: party,
      amount_cents: 10_000,
      occurred_on: Date.current
    )
    expect(res2).to be_success
    expect(res2.value!.data[:transaction].amount_cents).to eq(10_000)
  end

  it "rejects string amount_cents" do
    res = described_class.call(
      security_deposit: security_deposit,
      party: party,
      amount_cents: "10000",
      occurred_on: Date.current
    )
    expect(res).to be_failure
    expect(res.failure.code).to eq(:invalid_input)
  end

  it "rejects refund exceeding held liability" do
    result = described_class.call(
      security_deposit: security_deposit,
      party: party,
      amount: "2500.00",
      occurred_on: Date.new(2026, 1, 15)
    )
    expect(result).to be_failure
    expect(result.failure.code).to eq(:negative_deposit_liability)
  end

  it "rejects future date, user mismatch, missing date, or invalid inputs" do
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "100", occurred_on: Date.tomorrow).failure.code).to eq(:invalid_date)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "100", occurred_on: nil).failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "100", occurred_on: "").failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "100", occurred_on: "bad").failure.code).to eq(:invalid_input)

    other_user = create(:user)
    other_party = create(:party, user: other_user)
    expect(described_class.call(security_deposit: security_deposit, party: other_party, amount: "100", occurred_on: Date.current).failure.code).to eq(:party_user_mismatch)

    expect(described_class.call(security_deposit: SecurityDeposit.new, party: party, amount: "100", occurred_on: Date.current).failure.code).to eq(:invalid_deposit)
    expect(described_class.call(security_deposit: security_deposit, party: Party.new, amount: "100", occurred_on: Date.current).failure.code).to eq(:invalid_party)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: "-50", occurred_on: Date.current).failure.code).to eq(:invalid_input)
    expect(described_class.call(security_deposit: security_deposit, party: party, amount: nil, amount_cents: nil, occurred_on: Date.current).failure.code).to eq(:invalid_input)
  end

  it "handles posting failure gracefully" do
    allow(Accounting::PostEntryService).to receive(:call).and_return(
      ServiceResult.failure(error: "Posting error", code: :post_failed)
    )
    res = described_class.call(security_deposit: security_deposit, party: party, amount: "100", occurred_on: Date.current)
    expect(res).to be_failure
    expect(res.failure.code).to eq(:post_failed)
  end
end
