require "rails_helper"

RSpec.describe ImportedTransactions::UpdateService do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party) { create(:party, user: user) }
  let!(:tenancy) do
    t = create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
    create(:tenancy_party, tenancy: t, party: party, role: "tenant")
    t
  end
  let(:source_document) { create(:source_document, user: user) }

  it "rejects when transaction belongs to another user" do
    foreign_txn = create(:imported_transaction, user: other_user)
    result = described_class.call(user: user, transaction: foreign_txn, params: {})
    expect(result).to be_failure
    expect(result.failure.code).to eq(:not_found)
  end

  it "rejects updating a confirmed transaction" do
    confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)
    result = described_class.call(user: user, transaction: confirmed_txn, params: { amount: "100.00" })
    expect(result).to be_failure
    expect(result.failure.code).to eq(:immutable)
  end

  it "returns validation error on invalid input" do
    txn = create(:imported_transaction, user: user, source_document: source_document, status: "pending")
    result = described_class.call(user: user, transaction: txn, params: { amount: "-50.00" })
    expect(result).to be_failure
    expect(result.failure.code).to eq(:validation_error)
  end

  it "promotes ambiguous/unmatched transaction to matched when fully resolved" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      status: "ambiguous",
      transaction_kind: "unknown",
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 3, 24),
      payment_method: "zelle"
    )

    result = described_class.call(
      user: user,
      transaction: txn,
      params: {
        matched_party_id: party.id,
        matched_tenancy_id: tenancy.id,
        transaction_kind: "tenant_receipt"
      }
    )

    expect(result).to be_success
    txn.reload
    expect(txn.status).to eq("matched")
    expect(txn.matched_party).to eq(party)
    expect(txn.matched_tenancy).to eq(tenancy)
  end

  it "promotes unmatched transaction to matched even when transaction_kind remains unknown" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      status: "unmatched",
      transaction_kind: "unknown",
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 3, 24),
      payment_method: "zelle"
    )

    result = described_class.call(
      user: user,
      transaction: txn,
      params: {
        matched_party_id: party.id,
        matched_tenancy_id: tenancy.id
      }
    )

    expect(result).to be_success
    txn.reload
    expect(txn.status).to eq("matched")
    expect(txn.transaction_kind).to eq("unknown")
    expect(txn.confirmable?).to be(false) # matching is resolved, but posting-readiness is false
  end

  it "demotes matched transaction to unmatched when matched_tenancy is cleared" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      status: "matched",
      matched_party: party,
      matched_tenancy: tenancy
    )

    result = described_class.call(
      user: user,
      transaction: txn,
      params: { matched_tenancy_id: nil }
    )

    expect(result).to be_success
    txn.reload
    expect(txn.status).to eq("unmatched")
    expect(txn.matched_tenancy_id).to be_nil
  end

  it "demotes matched transaction to unmatched when matched_party is cleared" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      status: "matched",
      matched_party: party,
      matched_tenancy: tenancy
    )

    result = described_class.call(
      user: user,
      transaction: txn,
      params: { matched_party_id: nil }
    )

    expect(result).to be_success
    txn.reload
    expect(txn.status).to eq("unmatched")
    expect(txn.matched_party_id).to be_nil
  end

  it "retains failed status when failed transaction is edited without setting party or tenancy" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      status: "failed",
      matched_party: nil,
      matched_tenancy: nil
    )

    result = described_class.call(
      user: user,
      transaction: txn,
      params: { amount: "200.00" }
    )

    expect(result).to be_success
    txn.reload
    expect(txn.status).to eq("failed")
    expect(txn.amount_cents).to eq(20_000)
  end

  it "transitions failed transaction to unmatched when party is set without tenancy" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      status: "failed",
      matched_party: nil,
      matched_tenancy: nil
    )

    result = described_class.call(
      user: user,
      transaction: txn,
      params: { matched_party_id: party.id }
    )

    expect(result).to be_success
    txn.reload
    expect(txn.status).to eq("unmatched")
    expect(txn.matched_party).to eq(party)
  end

  it "preserves ambiguous status when editing non-matching fields" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      status: "ambiguous",
      transaction_kind: "unknown",
      matched_party: nil,
      matched_tenancy: nil,
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 3, 24),
      payment_method: "zelle"
    )

    result = described_class.call(
      user: user,
      transaction: txn,
      params: { amount: "200.00", transaction_kind: "tenant_receipt" }
    )

    expect(result).to be_success
    txn.reload
    expect(txn.status).to eq("ambiguous")
    expect(txn.amount_cents).to eq(20_000)
    expect(txn.transaction_kind).to eq("tenant_receipt")
  end

  it "transitions ambiguous to matched when both party and tenancy are resolved" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      status: "ambiguous",
      matched_party: nil,
      matched_tenancy: nil,
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 3, 24),
      payment_method: "zelle"
    )

    result = described_class.call(
      user: user,
      transaction: txn,
      params: { matched_party_id: party.id, matched_tenancy_id: tenancy.id }
    )

    expect(result).to be_success
    txn.reload
    expect(txn.status).to eq("matched")
  end

  it "transitions ambiguous to unmatched when only party is set" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      status: "ambiguous",
      matched_party: nil,
      matched_tenancy: nil,
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 3, 24),
      payment_method: "zelle"
    )

    result = described_class.call(
      user: user,
      transaction: txn,
      params: { matched_party_id: party.id }
    )

    expect(result).to be_success
    txn.reload
    expect(txn.status).to eq("unmatched")
    expect(txn.matched_party).to eq(party)
  end
end
