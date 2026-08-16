require "rails_helper"

RSpec.describe Receipts::VoidService, type: :service do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2026, 1, 1)) }
  let(:payer_party) { create(:party, user: user) }

  let!(:receipt_result) do
    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: payer_party,
      amount_cents: 100_000,
      received_on: Date.new(2026, 1, 10),
      payment_method: "zelle",
      external_reference: "ZEL123",
      memo: "January Rent"
    )
  end
  let(:receipt) { receipt_result.value!.data[:receipt] }

  describe ".call" do
    it "reverses the accounting entry and marks the receipt voided" do
      result = nil
      expect {
        result = described_class.call(receipt: receipt, reason: "Duplicate payment entered by mistake")
        expect(result).to be_success
        expect(receipt.reload.voided?).to be true
        expect(receipt.voided_at).to be_present
      }.to change(JournalEntry, :count).by(1)
       .and change(Posting, :count).by(2)

      reversal_entry = result.value!.data[:journal_entry]
      expect(reversal_entry).to be_present
      expect(reversal_entry.occurred_on).to eq(Date.new(2026, 1, 10))

      cash_posting = reversal_entry.postings.find { |p| p.account.key == "cash" }
      expect(cash_posting.amount_cents).to eq(-100_000)

      ar_posting = reversal_entry.postings.find { |p| p.account.key == "tenant_receivable" }
      expect(ar_posting.amount_cents).to eq(100_000)
    end

    it "always reverses dated at original received_on regardless of when void is called" do
      travel_to Date.new(2026, 6, 15) do
        result = described_class.call(receipt: receipt)
        expect(result).to be_success
        reversal_entry = result.value!.data[:journal_entry]
        expect(reversal_entry.occurred_on).to eq(Date.new(2026, 1, 10))
      end
    end

    it "restores the tenancy balance automatically" do
      create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.new(2026, 1, 1))
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 100_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1),
        service_period_start: Date.new(2026, 1, 1),
        service_period_end: Date.new(2026, 1, 31)
      )

      # Balance after payment was $0
      expect(tenancy.current_balance).to eq(BigDecimal("0.00"))

      # Void the payment
      described_class.call(receipt: receipt)

      # Balance should now be $1,000 owed
      expect(tenancy.current_balance).to eq(BigDecimal("1000.00"))
    end

    it "is idempotent if called multiple times" do
      res1 = described_class.call(receipt: receipt)
      expect(res1).to be_success

      expect {
        res2 = described_class.call(receipt: receipt)
        expect(res2).to be_success
      }.not_to change(JournalEntry, :count)
    end

    it "fails if receipt is already superseded by a replacement receipt" do
      replacement = create(:receipt, tenancy: tenancy, payer_party: payer_party)
      receipt.update_columns(voided_at: Time.current, superseded_by_id: replacement.id)

      result = described_class.call(receipt: receipt)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:already_superseded)
    end

    it "returns failure for unpersisted receipt" do
      result = described_class.call(receipt: Receipt.new)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_source)
    end

    it "returns failure if journal entry is missing" do
      allow(receipt).to receive_message_chain(:journal_entries, :find_by).and_return(nil)
      result = described_class.call(receipt: receipt)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
    end

    it "handles reverse service failure" do
      allow(Accounting::ReverseEntryService).to receive(:call).and_return(
        ServiceResult.failure(error: "Reverse error", code: :reverse_error)
      )
      result = described_class.call(receipt: receipt)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:reverse_error)
    end
  end
end
