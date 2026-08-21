require "rails_helper"

RSpec.describe RentCharges::GenerateThroughService do
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
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 150_000,
      due_day: 1,
      frequency: "monthly",
      effective_from: Date.new(2026, 1, 1),
      effective_until: Date.new(2026, 12, 31)
    )
  end

  describe ".call" do
    it "generates rent charges for all due months up through target date" do
      result = described_class.call(
        tenancy: tenancy,
        through: Date.new(2026, 3, 15)
      )

      expect(result).to be_success
      charges = result.value!.data[:charges]
      expect(charges.size).to eq(3) # Jan, Feb, Mar

      expect(tenancy.charges.rent.count).to eq(3)
      expect(tenancy.charges.rent.order(:service_period_start).pluck(:service_period_start)).to eq([
        Date.new(2026, 1, 1),
        Date.new(2026, 2, 1),
        Date.new(2026, 3, 1)
      ])
    end

    it "is idempotent on subsequent calls" do
      described_class.call(tenancy: tenancy, through: Date.new(2026, 3, 15))

      expect {
        result = described_class.call(tenancy: tenancy, through: Date.new(2026, 3, 15))
        expect(result).to be_success
      }.not_to change(Charge, :count)
    end

    it "returns failure for unpersisted or nil tenancy" do
      expect(described_class.call(tenancy: Tenancy.new)).to be_failure
      expect(described_class.call(tenancy: nil)).to be_failure
    end

    it "returns empty charges when commencement date is nil or after through date" do
      allow(tenancy).to receive(:commencement_date).and_return(nil)
      result_nil = described_class.call(tenancy: tenancy, through: Date.new(2026, 12, 1))
      expect(result_nil).to be_success
      expect(result_nil.value!.data[:charges]).to be_empty

      allow(tenancy).to receive(:commencement_date).and_call_original
      result = described_class.call(tenancy: tenancy, through: Date.new(2025, 12, 1))
      expect(result).to be_success
      expect(result.value!.data[:charges]).to be_empty
    end

    it "handles string and invalid through dates" do
      result = described_class.call(tenancy: tenancy, through: "2026-02-15")
      expect(result).to be_success
      expect(result.value!.data[:charges].size).to eq(2)

      invalid_res = described_class.call(tenancy: tenancy, through: "not-a-date")
      expect(invalid_res).to be_success
    end

    it "propagates failure when generate service fails" do
      allow(RentCharges::GenerateService).to receive(:call).and_return(
        ServiceResult.failure(error: "Generation error", code: :generation_error)
      )
      result = described_class.call(tenancy: tenancy, through: Date.new(2026, 2, 1))
      expect(result).to be_failure
      expect(result.failure.code).to eq(:generation_error)
    end
  end
end
