require "rails_helper"

RSpec.describe Accounting::SecurityDepositBalanceQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  it "returns 0 when no deposit postings exist" do
    expect(described_class.call(tenancy: tenancy)).to eq(0)
    expect(described_class.call(property: property)).to eq(0)
    expect(described_class.new(user: user).balance_as_of).to eq(0)
  end

  it "returns 0 when user or account is missing" do
    expect(described_class.new.balance_cents_as_of).to eq(0)

    user_no_acct = create(:user)
    expect(described_class.new(user: user_no_acct).balance_cents_as_of).to eq(0)
  end

  it "calculates held liability from posted transactions" do
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: security_deposit,
      party: party,
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 1, 1)
    )

    expect(described_class.call(tenancy: tenancy)).to eq(100_000)
    expect(described_class.call(property: property)).to eq(100_000)
    expect(described_class.call(user: user)).to eq(100_000)

    query = described_class.new(tenancy: tenancy)
    expect(query.balance_as_of).to eq(1000.0)

    # Add second received transaction
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: security_deposit,
      party: party,
      amount_cents: 50_000,
      occurred_on: Date.new(2026, 2, 1)
    )

    expect(described_class.call(tenancy: tenancy)).to eq(150_000)
    expect(described_class.call(property: property)).to eq(150_000)

    # As of Jan 15, should only see txn1
    expect(described_class.call(tenancy: tenancy, as_of: Date.new(2026, 1, 15))).to eq(100_000)

    # Refund $30,000 on March 1
    SecurityDepositTransactions::RefundService.call(
      security_deposit: security_deposit,
      party: party,
      amount_cents: 30_000,
      occurred_on: Date.new(2026, 3, 1)
    )

    expect(described_class.call(tenancy: tenancy)).to eq(120_000)
    expect(described_class.call(tenancy: tenancy, as_of: Date.new(2026, 2, 15))).to eq(150_000)
  end
end
