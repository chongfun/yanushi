require "rails_helper"

RSpec.describe TenancyParties::DestroyService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.new(2025, 1, 1),
      termination_date: Date.new(2025, 12, 31)
    )
  end
  let(:party1) { create(:party, user: user, display_name: "Alice") }
  let(:party2) { create(:party, user: user, display_name: "Bob") }

  let!(:tp1) do
    create(:tenancy_party,
      tenancy: tenancy,
      party: party1,
      role: "tenant",
      effective_from: Date.new(2025, 1, 1),
      effective_until: Date.new(2025, 12, 31)
    )
  end

  describe ".call" do
    it "fails when attempting to remove the sole tenant" do
      result = described_class.call(tenancy_party: tp1)

      expect(result).to be_failure
      expect(result.failure.error).to include("tenancy must maintain continuous tenant coverage")
      expect(TenancyParty.exists?(tp1.id)).to be true
    end

    it "fails when remaining tenant only covers part of the tenancy period" do
      create(:tenancy_party,
        tenancy: tenancy,
        party: party2,
        role: "tenant",
        effective_from: Date.new(2025, 1, 1),
        effective_until: Date.new(2025, 6, 30)
      )

      result = described_class.call(tenancy_party: tp1)

      expect(result).to be_failure
      expect(result.failure.error).to include("tenancy must maintain continuous tenant coverage")
      expect(TenancyParty.exists?(tp1.id)).to be true
    end

    it "succeeds when removing a tenant if another tenant covers the full duration" do
      create(:tenancy_party,
        tenancy: tenancy,
        party: party2,
        role: "tenant",
        effective_from: Date.new(2025, 1, 1),
        effective_until: Date.new(2025, 12, 31)
      )

      result = described_class.call(tenancy_party: tp1)

      expect(result).to be_success
      expect(TenancyParty.exists?(tp1.id)).to be false
    end

    it "succeeds when removing a guarantor" do
      guarantor_tp = create(:tenancy_party,
        tenancy: tenancy,
        party: party2,
        role: "guarantor",
        effective_from: Date.new(2025, 1, 1),
        effective_until: Date.new(2025, 12, 31)
      )

      result = described_class.call(tenancy_party: guarantor_tp)

      expect(result).to be_success
      expect(TenancyParty.exists?(guarantor_tp.id)).to be false
    end
  end
end
