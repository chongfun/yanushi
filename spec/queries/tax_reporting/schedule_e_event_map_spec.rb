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

  it "classifies deposit_applied and its reversal as review_required" do
    deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 100_000)
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: deposit,
      party: party,
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 1, 1)
    )
    charge = Charges::CreateFeeService.call(
      tenancy: tenancy,
      charge_kind: "other",
      description: "Repair",
      amount_cents: 50_000,
      charge_date: Date.new(2026, 1, 2)
    ).value!.data[:charge]

    app_res = SecurityDepositTransactions::ApplyService.call(
      security_deposit: deposit,
      charge: charge,
      amount_cents: 50_000,
      occurred_on: Date.new(2026, 1, 5)
    )
    app_entry = app_res.value!.data[:journal_entry]
    expect(described_class.classify_income_event(app_entry)).to eq(:review_required)
  end

  it "classifies unrecognized event types as review_required" do
    unknown_entry = build(:journal_entry, user: user, event_type: "unexpected_financial_event")
    expect(described_class.classify_income_event(unknown_entry)).to eq(:review_required)
  end

  it "classifies known event type with unexpected source_type as review_required" do
    mismatched_entry = build(
      :journal_entry,
      user: user,
      source_type: "CustomFinancialEvent",
      event_type: "receipt_posted"
    )
    expect(described_class.classify_income_event(mismatched_entry)).to eq(:review_required)
  end

  it "classifies reversal with unexpected original source_type as reversal_of_reviewed" do
    orig_entry = create(
      :journal_entry,
      user: user,
      source_type: "CustomFinancialEvent",
      event_type: "receipt_posted"
    )
    rev_entry = create(
      :journal_entry,
      user: user,
      source_type: "CustomFinancialEvent",
      event_type: "reversal",
      reversal_of: orig_entry
    )
    expect(described_class.classify_income_event(rev_entry)).to eq(:reversal_of_reviewed)
  end

  it "raises ArgumentError for reversals without reversal_of lineage and classifies excluded event reversals" do
    orphan_rev = build(:journal_entry, user: user, source_type: "CustomSource", event_type: "reversal", reversal_of: nil)
    expect {
      described_class.classify_income_event(orphan_rev)
    }.to raise_error(ArgumentError, /missing reversal_of lineage/)

    exp_orig = create(:journal_entry, user: user, source_type: "Expense", event_type: "expense_posted")
    exp_rev = create(:journal_entry, user: user, source_type: "Expense", event_type: "reversal", reversal_of: exp_orig)
    expect(described_class.classify_income_event(exp_rev)).to eq(:excluded)

    charge_orig = create(:journal_entry, user: user, source_type: "Charge", event_type: "charge_posted")
    charge_rev = create(:journal_entry, user: user, source_type: "Charge", event_type: "reversal", reversal_of: charge_orig)
    expect(described_class.classify_income_event(charge_rev)).to eq(:excluded)

    waiver_orig = create(:journal_entry, user: user, source_type: "Charge", event_type: "charge_waiver")
    waiver_rev = create(:journal_entry, user: user, source_type: "Charge", event_type: "reversal", reversal_of: waiver_orig)
    expect(described_class.classify_income_event(waiver_rev)).to eq(:excluded)

    dep_orig = create(:journal_entry, user: user, source_type: "SecurityDepositTransaction", event_type: "deposit_received")
    dep_rev = create(:journal_entry, user: user, source_type: "SecurityDepositTransaction", event_type: "reversal", reversal_of: dep_orig)
    expect(described_class.classify_income_event(dep_rev)).to eq(:excluded)

    ref_orig = create(:journal_entry, user: user, source_type: "SecurityDepositTransaction", event_type: "deposit_refunded")
    ref_rev = create(:journal_entry, user: user, source_type: "SecurityDepositTransaction", event_type: "reversal", reversal_of: ref_orig)
    expect(described_class.classify_income_event(ref_rev)).to eq(:excluded)
  end

  describe ".reviewable?" do
    it "returns true for :review_required events" do
      entry = build(:journal_entry, user: user, event_type: "deposit_applied", source_type: "SecurityDepositTransaction")
      expect(described_class.reviewable?(entry)).to be true

      unknown = build(:journal_entry, user: user, event_type: "settlement")
      expect(described_class.reviewable?(unknown)).to be true
    end

    it "returns false for ordinary mapped expenses and ordinary receipts" do
      exp = create(:expense, property: property)
      exp_entry = create(:journal_entry, user: user, event_type: "expense_posted", source: exp)
      create(:posting, journal_entry: exp_entry, property: property, amount_cents: 10_000, account: user.accounts.find_by!(key: "expense_repairs"))
      create(:posting, journal_entry: exp_entry, property: property, amount_cents: -10_000, account: user.accounts.find_by!(key: "cash"))
      expect(described_class.reviewable?(exp_entry)).to be false

      rec = create(:receipt, tenancy: tenancy)
      rec_entry = create(:journal_entry, user: user, event_type: "receipt_posted", source: rec)
      create(:posting, journal_entry: rec_entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "cash"))
      create(:posting, journal_entry: rec_entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "rental_income"))
      expect(described_class.reviewable?(rec_entry)).to be false
    end

    it "returns true for expense events with unmapped expense accounts" do
      unmapped_acct = create(:account, user: user, key: "expense_special", account_type: "expense")
      exp = create(:expense, property: property)
      exp_entry = create(:journal_entry, user: user, event_type: "expense_posted", source: exp)
      create(:posting, journal_entry: exp_entry, property: property, amount_cents: 10_000, account: unmapped_acct)
      create(:posting, journal_entry: exp_entry, property: property, amount_cents: -10_000, account: user.accounts.find_by!(key: "cash"))
      expect(described_class.reviewable?(exp_entry)).to be true
    end

    it "filters postings by property when property is provided" do
      prop_b = create(:property, user: user)
      exp = create(:expense, property: property)
      unmapped_acct = create(:account, user: user, key: "expense_special_prop_b", account_type: "expense")
      repairs_acct = user.accounts.find_by!(key: "expense_repairs")

      entry = create(:journal_entry, user: user, event_type: "expense_posted", source: exp)
      create(:posting, journal_entry: entry, property: property, amount_cents: 10_000, account: repairs_acct)
      create(:posting, journal_entry: entry, property: prop_b, amount_cents: 20_000, account: unmapped_acct)

      expect(described_class.reviewable?(entry, property: property)).to be false
      expect(described_class.reviewable?(entry, property: prop_b)).to be true
      expect(described_class.reviewable?(entry)).to be true
    end

    it "resolves property via unit and tenancy postings when filtering by property" do
      exp = create(:expense, property: property)
      unmapped_acct = create(:account, user: user, key: "expense_unit_unmapped", account_type: "expense")
      entry = create(:journal_entry, user: user, event_type: "expense_posted", source: exp)
      create(:posting, journal_entry: entry, property: nil, rentable_unit: unit, amount_cents: 10_000, account: unmapped_acct)
      create(:posting, journal_entry: entry, property: nil, tenancy: tenancy, amount_cents: -10_000, account: user.accounts.find_by!(key: "cash"))

      expect(described_class.reviewable?(entry, property: property)).to be true

      other_prop = create(:property, user: user)
      expect(described_class.reviewable?(entry, property: other_prop)).to be false
    end

    it "returns false for reversals" do
      exp = create(:expense, property: property)
      exp_entry = create(:journal_entry, user: user, event_type: "expense_posted", source: exp)
      rev_entry = create(:journal_entry, user: user, event_type: "reversal", reversal_of: exp_entry, source: exp)
      expect(described_class.reviewable?(rev_entry)).to be false
    end

    it "returns false for nil" do
      expect(described_class.reviewable?(nil)).to be false
    end
  end
end
