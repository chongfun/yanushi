require "rails_helper"

RSpec.describe Charges::CreateService do
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

  describe ".call" do
    it "atomically creates and posts a Charge, marking it posted" do
      result = described_class.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 7500,
        charge_date: Date.new(2026, 5, 10),
        due_on: Date.new(2026, 5, 10),
        description: "Late fee for May"
      )

      expect(result).to be_success
      charge = result.value!.data[:charge]
      entry = result.value!.data[:journal_entry]

      expect(charge.persisted?).to be true
      expect(charge.posted?).to be true
      expect(charge.posted_at).to eq(entry.posted_at)
      expect(charge.amount_cents).to eq(7500)
      expect(entry.source).to eq(charge)
    end

    it "accepts dollar amount as a string or numeric" do
      result = described_class.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount: "150.25",
        charge_date: Date.new(2026, 5, 10),
        due_on: Date.new(2026, 5, 10)
      )

      expect(result).to be_success
      expect(result.value!.data[:charge].amount_cents).to eq(15_025)
    end

    it "rolls back Charge creation if posting fails" do
      allow(Accounting::PostEntryService).to receive(:call).and_return(
        ServiceResult.failure(error: "Posting rejected", code: :posting_failed)
      )

      expect {
        result = described_class.call(
          tenancy: tenancy,
          charge_kind: "other",
          amount_cents: 5000
        )
        expect(result).to be_failure
        expect(result.failure.code).to eq(:posting_failed)
      }.not_to change(Charge, :count)

      expect(JournalEntry.count).to eq(0)
    end

    it "returns validation failure without posting if Charge is invalid" do
      expect {
        result = described_class.call(
          tenancy: tenancy,
          charge_kind: "other",
          amount_cents: -500
        )
        expect(result).to be_failure
        expect(result.failure.code).to eq(:validation_error)
      }.not_to change(Charge, :count)

      expect(JournalEntry.count).to eq(0)
    end
  end
end
