require "rails_helper"

RSpec.describe TenancyParties::UpdateService do
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
    it "ignores role and party_id attributes to preserve participation identity" do
      result = described_class.call(
        tenancy_party: tp1,
        attributes: { role: "guarantor", party_id: party2.id, effective_until: Date.new(2025, 12, 31) }
      )

      expect(result).to be_success
      expect(tp1.reload.role).to eq("tenant")
      expect(tp1.party_id).to eq(party1.id)
    end

    it "fails when ending the sole tenant before the tenancy termination date" do
      result = described_class.call(tenancy_party: tp1, attributes: { effective_until: Date.new(2025, 6, 30) })

      expect(result).to be_failure
      expect(result.failure.error).to include("Tenancy must maintain continuous tenant coverage throughout its duration")
      expect(tp1.reload.effective_until).to eq(Date.new(2025, 12, 31))
    end

    it "fails when changing dates to create a gap between tenants" do
      create(:tenancy_party,
        tenancy: tenancy,
        party: party2,
        role: "tenant",
        effective_from: Date.new(2025, 7, 1),
        effective_until: Date.new(2025, 12, 31)
      )

      # Changing tp1 to end June 15 creates a gap between June 16 and June 30
      result = described_class.call(tenancy_party: tp1, attributes: { effective_until: Date.new(2025, 6, 15) })

      expect(result).to be_failure
      expect(result.failure.error).to include("Tenancy must maintain continuous tenant coverage throughout its duration")
    end

    it "succeeds when shortening a tenant participation if a successor tenant covers the remainder" do
      create(:tenancy_party,
        tenancy: tenancy,
        party: party2,
        role: "tenant",
        effective_from: Date.new(2025, 7, 1),
        effective_until: Date.new(2025, 12, 31)
      )

      result = described_class.call(tenancy_party: tp1, attributes: { effective_until: Date.new(2025, 6, 30) })

      expect(result).to be_success
      expect(tp1.reload.effective_until).to eq(Date.new(2025, 6, 30))
    end

    it "caps effective_until with tenancy termination_date when blank effective_until is passed on terminated tenancy" do
      result = described_class.call(tenancy_party: tp1, attributes: { effective_until: "" })

      expect(result).to be_success
      expect(tp1.reload.effective_until).to eq(Date.new(2025, 12, 31))
    end

    it "handles model validation error when effective_until is before effective_from" do
      result = described_class.call(tenancy_party: tp1, attributes: { effective_until: Date.new(2024, 12, 31) })

      expect(result).to be_failure
      expect(result.failure.code).to eq(:validation_error)
    end
  end
end
