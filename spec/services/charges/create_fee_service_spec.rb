require "rails_helper"

RSpec.describe Charges::CreateFeeService do
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
    it "creates and posts a late_fee charge" do
      result = described_class.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        description: "Late fee"
      )

      expect(result).to be_success
      charge = result.value!.data[:charge]
      expect(charge.late_fee?).to be true
      expect(charge.amount_cents).to eq(5000)
    end

    it "creates and posts an other charge" do
      result = described_class.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 2500,
        description: "Key replacement fee"
      )

      expect(result).to be_success
      charge = result.value!.data[:charge]
      expect(charge.other?).to be true
      expect(charge.amount_cents).to eq(2500)
    end

    it "rejects invalid charge kinds like rent or reimbursement" do
      result = described_class.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
    end
  end
end
