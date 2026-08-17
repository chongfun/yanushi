require "rails_helper"

RSpec.describe Tenancies::UpdateService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party) { create(:party, user: user) }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      agreement_type: "month_to_month",
      commencement_date: Date.new(2025, 1, 1),
      termination_date: nil,
      late_period_days: 5
    )
  end
  let!(:term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 150_000,
      effective_from: Date.new(2025, 1, 1),
      effective_until: nil
    )
  end
  let!(:tenancy_party) do
    create(:tenancy_party,
      tenancy: tenancy,
      party: party,
      role: "tenant",
      effective_from: Date.new(2025, 1, 1),
      effective_until: nil
    )
  end

  describe ".call" do
    context "with valid update params capping open-ended tenancy" do
      let(:params) do
        {
          late_period_days: 10,
          termination_date: Date.new(2025, 6, 30)
        }
      end

      it "successfully updates tenancy and caps open-ended child records" do
        result = described_class.call(user: user, tenancy: tenancy, params: params)

        expect(result).to be_success
        expect(tenancy.reload.late_period_days).to eq(10)
        expect(tenancy.termination_date).to eq(Date.new(2025, 6, 30))
        expect(term.reload.effective_until).to eq(Date.new(2025, 6, 30))
        expect(tenancy_party.reload.effective_until).to eq(Date.new(2025, 6, 30))
      end
    end

    context "when extending a fixed-term tenancy" do
      let(:fixed_unit) { create(:rentable_unit, property: property, name: "Fixed Unit") }
      let(:fixed_tenancy) do
        create(:tenancy,
          rentable_unit: fixed_unit,
          agreement_type: "fixed_term",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: Date.new(2025, 12, 31)
        )
      end
      let!(:active_term) do
        create(:rent_term,
          tenancy: fixed_tenancy,
          amount_cents: 200_000,
          effective_from: Date.new(2025, 1, 1),
          effective_until: Date.new(2025, 12, 31)
        )
      end
      let!(:active_party) do
        create(:tenancy_party,
          tenancy: fixed_tenancy,
          party: party,
          role: "tenant",
          effective_from: Date.new(2025, 1, 1),
          effective_until: Date.new(2025, 12, 31)
        )
      end
      let!(:past_party) do
        create(:tenancy_party,
          tenancy: fixed_tenancy,
          party: create(:party, user: user, display_name: "Past Occupant"),
          role: "occupant",
          effective_from: Date.new(2025, 1, 1),
          effective_until: Date.new(2025, 6, 30)
        )
      end

      it "auto-extends child records ending at old termination date to new termination date" do
        result = described_class.call(
          user: user,
          tenancy: fixed_tenancy,
          params: { termination_date: Date.new(2026, 3, 31) }
        )

        expect(result).to be_success
        expect(fixed_tenancy.reload.termination_date).to eq(Date.new(2026, 3, 31))
        expect(active_term.reload.effective_until).to eq(Date.new(2026, 3, 31))
        expect(active_party.reload.effective_until).to eq(Date.new(2026, 3, 31))
        # Past record ending earlier remains untouched
        expect(past_party.reload.effective_until).to eq(Date.new(2025, 6, 30))
      end

      it "auto-extends child records to nil when converting fixed-term to open-ended" do
        result = described_class.call(
          user: user,
          tenancy: fixed_tenancy,
          params: { agreement_type: "month_to_month", termination_date: nil }
        )

        expect(result).to be_success
        expect(fixed_tenancy.reload.termination_date).to be_nil
        expect(active_term.reload.effective_until).to be_nil
        expect(active_party.reload.effective_until).to be_nil
        expect(past_party.reload.effective_until).to eq(Date.new(2025, 6, 30))
      end
    end

    context "when new termination date is before a rent term start date" do
      let(:params) do
        {
          termination_date: Date.new(2024, 12, 31)
        }
      end

      it "prevents update and returns failure" do
        result = described_class.call(user: user, tenancy: tenancy, params: params)

        expect(result).to be_failure
        expect(result.failure.error).to include("Cannot set termination date before the start of existing rent term")
      end
    end

    context "when new termination date is before a participant start date" do
      before do
        term.update!(effective_from: Date.new(2025, 1, 1))
        tenancy_party.update!(effective_from: Date.new(2025, 4, 1))
      end

      let(:params) do
        {
          termination_date: Date.new(2025, 3, 31)
        }
      end

      it "prevents update and returns failure" do
        result = described_class.call(user: user, tenancy: tenancy, params: params)

        expect(result).to be_failure
        expect(result.failure.error).to include("Cannot set termination date before existing participant start date")
      end

      it "returns validation error when termination_date is a malformed string" do
        params = { termination_date: "not-a-date" }
        result = described_class.call(user: user, tenancy: tenancy, params: params)

        expect(result).to be_failure
        expect(result.failure.code).to eq(:validation_error)
        expect(result.failure.error).to include("Termination date is invalid")
      end
    end

    context "when new termination date is before live rent charges end date" do
      before do
        create(:charge, :rent_charge,
          tenancy: tenancy,
          rent_term: term,
          amount_cents: 150_000,
          charge_date: Date.new(2025, 8, 1),
          due_on: Date.new(2025, 8, 1),
          service_period_start: Date.new(2025, 8, 1),
          service_period_end: Date.new(2025, 8, 31),
          posted_at: Time.current
        )
      end

      it "rejects shortening termination date if live rent charge exceeds new date" do
        result = described_class.call(
          tenancy: tenancy,
          params: { termination_date: Date.new(2025, 7, 31) }
        )

        expect(result).to be_failure
        expect(result.failure.code).to eq(:conflict)
        expect(result.failure.error).to include("Cannot set termination date before existing rent charges end date")
      end
    end

    it "fails when continuous tenant coverage is broken during update" do
      allow(tenancy).to receive(:continuous_tenant_coverage?).and_return(false)
      result = described_class.call(
        tenancy: tenancy,
        params: { late_period_days: 15 }
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:validation_error)
      expect(result.failure.error).to include("continuous tenant coverage")
    end
  end
end
