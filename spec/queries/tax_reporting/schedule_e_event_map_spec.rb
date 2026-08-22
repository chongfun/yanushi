require "rails_helper"

RSpec.describe TaxReporting::ScheduleEEventMap do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    create(:tenancy_party, tenancy: tenancy, party: party)
  end

  it "classifies ordinary receipt events as rents_received" do
    res = Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 100_000,
      received_on: Date.new(2026, 1, 5),
      payment_method: "check"
    )
    entry = res.value!.data[:journal_entry]

    expect(described_class.classify_income_event(entry)).to eq(:rents_received)
  end

  it "classifies receipt reversals as rents_received_reversal" do
    res = Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 100_000,
      received_on: Date.new(2026, 1, 5),
      payment_method: "check"
    )
    receipt = res.value!.data[:receipt]
    rev_res = Receipts::VoidService.call(receipt: receipt)
    rev_entry = rev_res.value!.data[:journal_entry]

    expect(described_class.classify_income_event(rev_entry)).to eq(:rents_received_reversal)
  end

  it "excludes charges and security deposit custody events from ordinary rental receipts" do
    charge_res = Charges::CreateFeeService.call(
      tenancy: tenancy,
      charge_kind: "late_fee",
      amount_cents: 5_000,
      charge_date: Date.new(2026, 1, 2)
    )
    charge_entry = charge_res.value!.data[:journal_entry]
    expect(described_class.classify_income_event(charge_entry)).to eq(:excluded)

    deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 100_000)
    dep_res = SecurityDepositTransactions::ReceiveService.call(
      security_deposit: deposit,
      party: party,
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 1, 1)
    )
    dep_entry = dep_res.value!.data[:journal_entry]
    expect(described_class.classify_income_event(dep_entry)).to eq(:excluded)

    ref_res = SecurityDepositTransactions::RefundService.call(
      security_deposit: deposit,
      party: party,
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 1, 10)
    )
    ref_entry = ref_res.value!.data[:journal_entry]
    expect(described_class.classify_income_event(ref_entry)).to eq(:excluded)
  end
end
