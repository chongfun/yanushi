require "rails_helper"

RSpec.describe Charges::VoidService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.new(2026, 1, 1),
      termination_date: Date.new(2026, 12, 31)
    )
  end
  let(:charge_result) do
    Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "late_fee",
      amount_cents: 5000,
      charge_date: Date.new(2026, 5, 10),
      due_on: Date.new(2026, 5, 10),
      description: "May late fee"
    )
  end
  let(:charge) { charge_result.value!.data[:charge] }
  let(:original_entry) { charge_result.value!.data[:journal_entry] }

  describe ".call" do
    it "voids a charge by creating a reversal journal entry and setting voided_at" do
      expect(charge).not_to be_voided

      result = described_class.call(
        charge: charge,
        occurred_on: Date.new(2026, 5, 15),
        reason: "Assessed in error"
      )

      expect(result).to be_success
      reversal_entry = result.value!.data[:journal_entry]

      expect(charge.reload).to be_voided
      expect(charge.voided_at).to be_present

      expect(reversal_entry.event_type).to eq("reversal")
      expect(reversal_entry.reversal_of_id).to eq(original_entry.id)
      expect(reversal_entry.occurred_on).to eq(Date.new(2026, 5, 15))

      # Verifies exact negative postings
      rev_dr = reversal_entry.postings.find_by(amount_cents: -5000)
      rev_cr = reversal_entry.postings.find_by(amount_cents: 5000)

      expect(rev_dr.account.key).to eq("tenant_receivable")
      expect(rev_cr.account.key).to eq("late_fee_income")
    end

    it "is idempotent on repeated calls with matching arguments" do
      result1 = described_class.call(charge: charge, occurred_on: Date.new(2026, 5, 15), reason: "Error")
      expect(result1).to be_success

      expect {
        result2 = described_class.call(charge: charge, occurred_on: Date.new(2026, 5, 15), reason: "Error")
        expect(result2).to be_success
        expect(result2.value!.data[:journal_entry].id).to eq(result1.value!.data[:journal_entry].id)
      }.not_to change(JournalEntry, :count)
    end

    it "rejects conflicting retries with different dates or reasons" do
      result1 = described_class.call(charge: charge, occurred_on: Date.new(2026, 5, 15), reason: "Fee waived")
      expect(result1).to be_success

      # Different date
      result_diff_date = described_class.call(charge: charge, occurred_on: Date.new(2026, 5, 20), reason: "Fee waived")
      expect(result_diff_date).to be_failure
      expect(result_diff_date.failure.code).to eq(:idempotency_conflict)

      # Different reason
      result_diff_reason = described_class.call(charge: charge, occurred_on: Date.new(2026, 5, 15), reason: "Assessed in error")
      expect(result_diff_reason).to be_failure
      expect(result_diff_reason.failure.code).to eq(:idempotency_conflict)
    end

    it "reverses charge as a period event, preserving prior point-in-time balances" do
      expect(charge).to be_present
      # May 10: Late fee $50 assessed -> Balance on May 12 is $50
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 5, 12))).to eq(50.0)

      # May 15: Landlord waives the fee
      result = described_class.call(charge: charge, occurred_on: Date.new(2026, 5, 15), reason: "Fee waived by landlord")
      expect(result).to be_success

      # Balance on May 12 remains $50 (fee existed then)
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 5, 12))).to eq(50.0)
      # Balance on May 15 is $0 (reversal is effective May 15)
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 5, 15))).to eq(0.0)
    end

    it "ensures reversal date is at least the original entry date" do
      result = described_class.call(
        charge: charge,
        occurred_on: Date.new(2026, 5, 1) # Earlier than charge_date (2026-05-10)
      )

      expect(result).to be_success
      reversal = result.value!.data[:journal_entry]
      expect(reversal.occurred_on).to eq(Date.new(2026, 5, 10))
    end

    it "rejects malformed occurred_on dates with :invalid_input" do
      result = described_class.call(charge: charge, occurred_on: "garbage")
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
      expect(result.failure.error).to eq("Invalid occurred on date")

      result2 = described_class.call(charge: charge, occurred_on: "invalid-date-string")
      expect(result2).to be_failure
      expect(result2.failure.code).to eq(:invalid_input)
    end

    it "returns failure for unpersisted charge" do
      result = described_class.call(charge: Charge.new)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_source)
    end

    it "returns failure if journal entry is missing" do
      allow(charge).to receive_message_chain(:journal_entries, :find_by).and_return(nil)
      result = described_class.call(charge: charge)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
    end

    it "handles reverse service failure" do
      allow(Accounting::ReverseEntryService).to receive(:call).and_return(
        ServiceResult.failure(error: "Cannot reverse", code: :reverse_failed)
      )
      result = described_class.call(charge: charge)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:reverse_failed)
    end
  end
end
