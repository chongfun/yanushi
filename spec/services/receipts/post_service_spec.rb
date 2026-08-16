require "rails_helper"

RSpec.describe Receipts::PostService, type: :service do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:payer_party) { create(:party, user: user) }
  let(:receipt) do
    create(:receipt,
      user: user,
      tenancy: tenancy,
      payer_party: payer_party,
      amount_cents: 150_000,
      received_on: Date.new(2026, 1, 15),
      payment_method: "zelle",
      external_reference: "ZEL123",
      memo: "January Rent"
    )
  end

  describe ".call" do
    it "creates a balanced journal entry posting Dr Cash and Cr Tenant Receivable" do
      result = described_class.call(receipt: receipt)
      expect(result).to be_success

      entry = result.value!.data[:journal_entry]
      expect(entry.source).to eq(receipt)
      expect(entry.event_type).to eq("receipt_posted")
      expect(entry.occurred_on).to eq(Date.new(2026, 1, 15))
      expect(entry.user).to eq(user)

      postings = entry.postings.includes(:account, :party, :tenancy, :property, :rentable_unit)
      expect(postings.count).to eq(2)

      cash_posting = postings.find { |p| p.account.key == "cash" }
      expect(cash_posting.amount_cents).to eq(150_000)
      expect(cash_posting.party).to eq(payer_party)
      expect(cash_posting.tenancy).to eq(tenancy)
      expect(cash_posting.property).to eq(property)
      expect(cash_posting.rentable_unit).to eq(unit)

      receivable_posting = postings.find { |p| p.account.key == "tenant_receivable" }
      expect(receivable_posting.amount_cents).to eq(-150_000)
      expect(receivable_posting.party).to eq(payer_party)
      expect(receivable_posting.tenancy).to eq(tenancy)
      expect(receivable_posting.property).to eq(property)
      expect(receivable_posting.rentable_unit).to eq(unit)
    end

    it "fails if receipt is voided" do
      receipt.update_columns(voided_at: Time.current)
      result = described_class.call(receipt: receipt)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_state)
    end

    it "fails if receipt is not a persisted Receipt" do
      unpersisted = build(:receipt)
      result = described_class.call(receipt: unpersisted)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_source)
    end
  end
end
