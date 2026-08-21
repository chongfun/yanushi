require "rails_helper"

RSpec.describe Receipts::CorrectService, type: :service do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit1) { create(:rentable_unit, property: property) }
  let(:unit2) { create(:rentable_unit, property: property) }
  let(:tenancy1) { create(:tenancy, rentable_unit: unit1, commencement_date: Date.new(2026, 1, 1)) }
  let(:tenancy2) { create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2026, 1, 1)) }
  let(:party_alice) { create(:party, user: user, display_name: "Alice Tenant") }
  let(:party_bob) { create(:party, user: user, display_name: "Bob Tenant") }

  let!(:receipt_result) do
    Receipts::CreateService.call(
      tenancy: tenancy1,
      payer_party: party_alice,
      amount_cents: 200_000,
      received_on: Date.new(2026, 1, 15),
      payment_method: "zelle",
      external_reference: "ZEL123",
      memo: "January Rent"
    )
  end
  let(:receipt) { receipt_result.value!.data[:receipt] }

  describe ".call" do
    it "corrects the amount by reversing the original and creating a replacement" do
      result = nil
      expect {
        result = described_class.call(
          receipt: receipt,
          amount_cents: 210_000
        )
        expect(result).to be_success
      }.to change(Receipt, :count).by(1)
       .and change(JournalEntry, :count).by(2)
       .and change(Posting, :count).by(4)

      replacement = result.value!.data[:receipt]
      expect(replacement.amount_cents).to eq(210_000)
      expect(replacement.payer_party).to eq(party_alice)
      expect(replacement.tenancy).to eq(tenancy1)
      expect(replacement.posted?).to be true

      receipt.reload
      expect(receipt.voided?).to be true
      expect(receipt.superseded?).to be true
      expect(receipt.superseded_by).to eq(replacement)

      # Check net ledger balance for tenancy1
      # Initial: +2100 credit
      expect(tenancy1.current_balance).to eq(BigDecimal("-2100.00"))
    end

    it "corrects the tenancy by moving receivable credit between tenancies" do
      result = described_class.call(
        receipt: receipt,
        tenancy: tenancy2
      )
      expect(result).to be_success
      replacement = result.value!.data[:receipt]
      expect(replacement.tenancy).to eq(tenancy2)

      # Tenancy 1 balance is back to $0
      expect(tenancy1.current_balance).to eq(BigDecimal("0.00"))
      # Tenancy 2 has $2,000 credit
      expect(tenancy2.current_balance).to eq(BigDecimal("-2000.00"))
    end

    it "corrects the payer party while preserving original audit trail" do
      result = described_class.call(
        receipt: receipt,
        payer_party: party_bob
      )
      expect(result).to be_success
      replacement = result.value!.data[:receipt]
      expect(replacement.payer_party).to eq(party_bob)

      # Verify postings on replacement carry Bob
      replacement_entry = replacement.journal_entries.find_by(event_type: "receipt_posted")
      expect(replacement_entry.postings.map(&:party).uniq).to eq([ party_bob ])
    end

    it "allows replacement to retain the same external reference" do
      result = described_class.call(
        receipt: receipt,
        amount_cents: 220_000,
        external_reference: "ZEL123"
      )
      expect(result).to be_success
      replacement = result.value!.data[:receipt]
      expect(replacement.external_reference).to eq("ZEL123")
    end

    it "is idempotent for identical correction requests including string received_on" do
      res1 = described_class.call(
        receipt: receipt,
        amount_cents: 210_000,
        received_on: "2026-01-15",
        payment_method: "ZELLE",
        external_reference: " ZEL123 ",
        memo: " Updated Memo "
      )
      expect(res1).to be_success
      replacement1 = res1.value!.data[:receipt]

      expect {
        res2 = described_class.call(
          receipt: receipt,
          amount_cents: 210_000,
          received_on: "2026-01-15",
          payment_method: "zelle",
          external_reference: "ZEL123",
          memo: "Updated Memo"
        )
        expect(res2).to be_success
        expect(res2.value!.data[:receipt]).to eq(replacement1)
      }.not_to change(Receipt, :count)
    end

    it "rejects invalid received_on string" do
      bad_res = described_class.call(receipt: receipt, received_on: "not-a-date")
      expect(bad_res).to be_failure
      expect(bad_res.failure.code).to eq(:invalid_input)
      expect(bad_res.failure.error).to eq("Received on must be a valid date")
    end

    it "rejects a conflicting correction on an already superseded receipt" do
      described_class.call(receipt: receipt, amount_cents: 210_000)

      conflict_result = described_class.call(receipt: receipt, amount_cents: 250_000)
      expect(conflict_result).to be_failure
      expect(conflict_result.failure.code).to eq(:already_superseded)
    end

    it "rejects correcting a voided receipt" do
      Receipts::VoidService.call(receipt: receipt)

      result = described_class.call(receipt: receipt, amount_cents: 210_000)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:already_voided)
    end

    it "serializes concurrent corrections under row lock" do
      results = []
      threads = 2.times.map do |i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            results << described_class.call(
              receipt: receipt,
              amount_cents: 210_000 + (i * 10_000)
            )
          end
        end
      end
      threads.each(&:join)

      successes = results.select(&:success?)
      failures = results.select(&:failure?)

      expect(successes.count).to eq(1)
      expect(failures.count).to eq(1)
      expect(failures.first.failure.code).to eq(:already_superseded)
      expect(receipt.reload.superseded_by).to be_present
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

    it "returns failure for invalid or fractional amount" do
      bad_res = described_class.call(receipt: receipt, amount: "invalid")
      expect(bad_res).to be_failure
      expect(bad_res.failure.code).to eq(:invalid_amount)

      frac_res = described_class.call(receipt: receipt, amount: "100.555")
      expect(frac_res).to be_failure
      expect(frac_res.failure.code).to eq(:invalid_amount)
    end

    it "rejects moving receipt to another user's tenancy" do
      other_user = create(:user)
      other_prop = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_prop)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_party = create(:party, user: other_user)

      expect {
        result = described_class.call(
          receipt: receipt,
          tenancy: other_tenancy,
          payer_party: other_party
        )
        expect(result).to be_failure
        expect(result.failure.code).to eq(:ownership_mismatch)
        expect(result.failure.error).to eq("Cannot move receipt to another user's tenancy")
      }.not_to change(Receipt, :count)

      expect(receipt.reload.active?).to be true
      expect(receipt.voided?).to be false
      expect(receipt.superseded?).to be false
      expect(JournalEntry.where(event_type: "receipt_reversal")).to be_empty
    end

    it "rejects assigning payer belonging to another user" do
      other_user = create(:user)
      other_party = create(:party, user: other_user)

      expect {
        result = described_class.call(
          receipt: receipt,
          payer_party: other_party
        )
        expect(result).to be_failure
        expect(result.failure.code).to eq(:ownership_mismatch)
        expect(result.failure.error).to eq("Cannot assign payer belonging to another user")
      }.not_to change(Receipt, :count)

      expect(receipt.reload.active?).to be true
      expect(receipt.voided?).to be false
      expect(receipt.superseded?).to be false
    end

    it "handles reverse service failure" do
      allow(Accounting::ReverseEntryService).to receive(:call).and_return(
        ServiceResult.failure(error: "Reverse failed", code: :reverse_failed)
      )
      result = described_class.call(receipt: receipt, amount_cents: 210_000)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:reverse_failed)
    end

    it "handles replacement post failure" do
      allow(Receipts::PostService).to receive(:call).and_return(
        ServiceResult.failure(error: "Post failed", code: :post_failed)
      )
      result = described_class.call(receipt: receipt, amount_cents: 210_000)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:post_failed)
    end

    it "allows updating payment_method and external_reference" do
      res = described_class.call(
        receipt: receipt,
        payment_method: "venmo",
        external_reference: "VEN123"
      )
      expect(res).to be_success
      rep = res.value!.data[:receipt]
      expect(rep.payment_method).to eq("venmo")
      expect(rep.external_reference).to eq("VEN123")
    end
  end
end
