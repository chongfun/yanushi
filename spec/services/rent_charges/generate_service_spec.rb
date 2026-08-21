require "rails_helper"

RSpec.describe RentCharges::GenerateService do
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
      amount_cents: 180_000,
      due_day: 1,
      frequency: "monthly",
      effective_from: Date.new(2026, 1, 1),
      effective_until: Date.new(2026, 12, 31)
    )
  end

  describe ".call" do
    it "generates and posts a rent charge for the specified month" do
      result = described_class.call(
        tenancy: tenancy,
        service_month: Date.new(2026, 3, 1)
      )

      expect(result).to be_success
      charge = result.value!.data[:charge]
      entry = result.value!.data[:journal_entry]

      expect(charge.rent?).to be true
      expect(charge.amount_cents).to eq(180_000)
      expect(charge.charge_date).to eq(Date.new(2026, 3, 1))
      expect(charge.due_on).to eq(Date.new(2026, 3, 1))
      expect(charge.service_period_start).to eq(Date.new(2026, 3, 1))
      expect(charge.service_period_end).to eq(Date.new(2026, 3, 31))
      expect(charge.description).to eq("Rent - March 2026")
      expect(charge.posted?).to be true
      expect(entry).to be_present
    end

    it "is idempotent on repeated calls for the same month" do
      result1 = described_class.call(tenancy: tenancy, service_month: Date.new(2026, 4, 1))
      expect(result1).to be_success

      expect {
        result2 = described_class.call(tenancy: tenancy, service_month: Date.new(2026, 4, 15))
        expect(result2).to be_success
        expect(result2.value!.data[:charge].id).to eq(result1.value!.data[:charge].id)
      }.not_to change(Charge, :count)
    end

    it "returns success nil if there is no active rent term covering the month" do
      result = described_class.call(tenancy: tenancy, service_month: Date.new(2027, 2, 1))
      expect(result).to be_success
      expect(result.value!.data).to be_nil
    end

    it "returns failure for unpersisted tenancy" do
      result = described_class.call(tenancy: Tenancy.new, service_month: Date.new(2026, 3, 1))
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
    end

    it "returns failure for invalid service month" do
      result = described_class.call(tenancy: tenancy, service_month: "invalid-date")
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
    end

    it "returns conflict failure when existing charge has different amount" do
      described_class.call(tenancy: tenancy, service_month: Date.new(2026, 3, 1))
      existing = tenancy.charges.rent.first
      existing.update_columns(amount_cents: 999_000)

      result = described_class.call(tenancy: tenancy, service_month: Date.new(2026, 3, 1))
      expect(result).to be_failure
      expect(result.failure.code).to eq(:conflict)
    end
  end
end
