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
      expect(tenancy.charges.rent.pluck(:service_period_start)).to eq([
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
  end
end
