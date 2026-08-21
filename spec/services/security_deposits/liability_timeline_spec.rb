require "rails_helper"

RSpec.describe SecurityDeposits::LiabilityTimeline do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  it "validates that cumulative liability is non-negative at all dates" do
    # Jan 1: Receive $1,000
    txn1 = create(:security_deposit_transaction, :received, :posted, security_deposit: security_deposit, party: party, amount_cents: 100_000, occurred_on: Date.new(2026, 1, 1))
    # Jan 10: Refund $1,000
    create(:security_deposit_transaction, :refunded, :posted, security_deposit: security_deposit, party: party, amount_cents: 100_000, occurred_on: Date.new(2026, 1, 10))
    # Jan 20: Receive $500
    create(:security_deposit_transaction, :received, :posted, security_deposit: security_deposit, party: party, amount_cents: 50_000, occurred_on: Date.new(2026, 1, 20))

    # Proposal 1: Valid Jan 25 refund $500 with string date
    res1 = described_class.validate(
      security_deposit: security_deposit,
      additions: [ { occurred_on: "2026-01-25", delta_cents: -50_000 } ]
    )
    expect(res1).to be_success
    expect(res1.value!.data[:final_balance_cents]).to eq(0)

    # Proposal 2: Invalid backdated Jan 5 refund $500 (would make Jan 10 balance -$500)
    res2 = described_class.validate(
      security_deposit: security_deposit,
      additions: [ { occurred_on: Date.new(2026, 1, 5), delta_cents: -50_000 } ]
    )
    expect(res2).to be_failure
    expect(res2.failure.code).to eq(:negative_deposit_liability)
    expect(res2.failure.data[:as_of]).to eq(Date.new(2026, 1, 10))

    # Proposal 3: Single scalar removing_ids
    res3 = described_class.validate(
      security_deposit: security_deposit,
      removing_ids: txn1.id,
      additions: [ { occurred_on: Date.new(2026, 1, 1), delta_cents: 150_000 } ]
    )
    expect(res3).to be_success
  end
end
