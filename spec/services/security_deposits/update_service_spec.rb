require "rails_helper"

RSpec.describe SecurityDeposits::UpdateService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000, due_on: Date.current) }

  it "updates requirement when no transactions exist" do
    result = described_class.call(
      security_deposit: security_deposit,
      required_amount: "2500.00",
      due_on: Date.current + 10.days
    )

    expect(result).to be_success
    deposit = result.value!.data[:security_deposit]
    expect(deposit.required_amount_cents).to eq(250_000)
    expect(deposit.due_on).to eq(Date.current + 10.days)
  end

  it "accepts integer cents, numeric amount, and string due_on" do
    res1 = described_class.call(
      security_deposit: security_deposit,
      required_amount_cents: 300_000,
      due_on: "2026-09-15"
    )
    expect(res1).to be_success
    expect(security_deposit.reload.required_amount_cents).to eq(300_000)
    expect(security_deposit.due_on).to eq(Date.new(2026, 9, 15))

    res2 = described_class.call(
      security_deposit: security_deposit,
      required_amount: 3500
    )
    expect(res2).to be_success
    expect(security_deposit.reload.required_amount_cents).to eq(350_000)
  end

  it "rejects string required_amount_cents" do
    res = described_class.call(
      security_deposit: security_deposit,
      required_amount_cents: "300000"
    )
    expect(res).to be_failure
    expect(res.failure.code).to eq(:invalid_amount)
  end

  it "rejects update when transactions exist" do
    create(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party, amount_cents: 50_000)

    result = described_class.call(
      security_deposit: security_deposit,
      required_amount: "3000.00"
    )
    expect(result).to be_failure
    expect(result.failure.code).to eq(:immutable_requirement)
  end

  it "rejects invalid source, amount, or due_on" do
    expect(described_class.call(security_deposit: SecurityDeposit.new, required_amount: "100").failure.code).to eq(:invalid_source)
    expect(described_class.call(security_deposit: security_deposit, required_amount: "-50.00").failure.code).to eq(:invalid_amount)
    expect(described_class.call(security_deposit: security_deposit, required_amount: "100.999").failure.code).to eq(:invalid_amount)
    expect(described_class.call(security_deposit: security_deposit, required_amount_cents: "invalid").failure.code).to eq(:invalid_amount)
    expect(described_class.call(security_deposit: security_deposit, due_on: "not-a-date").failure.code).to eq(:invalid_due_on)
  end

  it "handles validation failure on save" do
    allow(security_deposit).to receive(:save).and_return(false)
    res = described_class.call(security_deposit: security_deposit, required_amount: "2500.00")
    expect(res).to be_failure
    expect(res.failure.code).to eq(:validation_error)
  end
end
