require "rails_helper"

RSpec.describe TenancyParties::CreateService do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.new(2025, 1, 1),
      termination_date: Date.new(2025, 12, 31)
    )
  end
  let(:party) { create(:party, user: user) }

  describe ".call" do
    it "creates a participant with bounded effective_until on terminated tenancy" do
      result = described_class.call(
        tenancy: tenancy,
        user: user,
        params: { party_id: party.id, role: "tenant", effective_from: Date.new(2025, 1, 1) }
      )

      expect(result).to be_success
      tp = result.value!.data[:tenancy_party]
      expect(tp.role).to eq("tenant")
      expect(tp.effective_until).to eq(Date.new(2025, 12, 31))
    end

    it "infers owner from tenancy property when user argument is omitted" do
      result = described_class.call(
        tenancy: tenancy,
        params: { party_id: party.id, role: "tenant", effective_from: Date.new(2025, 1, 1) }
      )

      expect(result).to be_success
      tp = result.value!.data[:tenancy_party]
      expect(tp.effective_until).to eq(Date.new(2025, 12, 31))
    end

    it "derives owner when user is omitted with explicit effective_until" do
      result = described_class.call(
        tenancy: tenancy,
        params: { party_id: party.id, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30) }
      )

      expect(result).to be_success
      tp = result.value!.data[:tenancy_party]
      expect(tp.effective_until).to eq(Date.new(2025, 6, 30))
    end

    it "fails when tenancy has no property and user is omitted" do
      allow(tenancy).to receive(:property).and_return(nil)
      result = described_class.call(
        tenancy: tenancy,
        params: { party_id: party.id, role: "tenant", effective_from: Date.new(2025, 1, 1) }
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
    end

    it "fails when party does not belong to user" do
      other_party = create(:party, user: other_user)
      result = described_class.call(
        tenancy: tenancy,
        user: user,
        params: { party_id: other_party.id, role: "tenant" }
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
    end

    it "handles invalid role with validation error" do
      result = described_class.call(
        tenancy: tenancy,
        user: user,
        params: { party_id: party.id, role: "nonexistent_role" }
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:validation_error)
      expect(result.failure.error).to include("Role is not included in the list")
    end

    it "handles model validation failures" do
      result = described_class.call(
        tenancy: tenancy,
        user: user,
        params: { party_id: party.id, role: "tenant", effective_from: Date.new(2024, 1, 1) }
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:validation_error)
      expect(result.failure.error).to include("Effective from")
    end

    context "concurrency with simultaneous tenancy termination" do
      let(:other_party) { create(:party, user: user, display_name: "Other Tenant") }
      let(:open_tenancy) do
        create(:tenancy,
          rentable_unit: create(:rentable_unit, property: property, name: "Open Unit"),
          agreement_type: "month_to_month",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: nil
        )
      end
      let!(:existing_tp) do
        create(:tenancy_party,
          tenancy: open_tenancy,
          party: party,
          role: "tenant",
          effective_from: Date.new(2025, 1, 1),
          effective_until: nil
        )
      end

      it "locks parent tenancy and bounds effective_until to freshly committed termination date" do
        # Process A terminates open tenancy at 2025-06-30
        update_result = Tenancies::UpdateService.call(
          tenancy: open_tenancy,
          params: { termination_date: Date.new(2025, 6, 30) }
        )
        expect(update_result).to be_success

        # Process B creates another participant without passing explicit effective_until
        result = described_class.call(
          tenancy: open_tenancy,
          user: user,
          params: { party_id: other_party.id, role: "occupant", effective_from: Date.new(2025, 1, 1) }
        )

        expect(result).to be_success
        tp = result.value!.data[:tenancy_party]
        expect(tp.effective_until).to eq(Date.new(2025, 6, 30))
      end
    end
  end
end
