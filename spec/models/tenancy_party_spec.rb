require "rails_helper"

RSpec.describe TenancyParty, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:tenancy) }
    it { is_expected.to belong_to(:party) }
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:role).with_values(TenancyParty::ROLES.index_by(&:itself)).backed_by_column_of_type(:string) }

    it "validates enum assignment without raising ArgumentError" do
      tp = build(:tenancy_party, role: "invalid_role")
      expect(tp).not_to be_valid
      expect(tp.errors[:role]).to include("is not included in the list")
    end
  end

  describe "validations" do
    subject { build(:tenancy_party) }

    it { is_expected.to validate_presence_of(:role) }
    it { is_expected.to validate_presence_of(:effective_from) }

    it "validates effective_until is on or after effective_from" do
      tp = build(:tenancy_party, effective_from: Date.new(2025, 5, 1), effective_until: Date.new(2025, 4, 30))
      expect(tp).not_to be_valid
      expect(tp.errors[:effective_until]).to include("must be on or after effective from date")
    end

    describe "effective date boundaries relative to tenancy" do
      let(:tenancy) do
        create(:tenancy, commencement_date: Date.new(2025, 1, 1), termination_date: Date.new(2025, 12, 31))
      end
      let(:party) { create(:party, user: tenancy.rentable_unit.property.user) }

      it "prevents effective_from before tenancy commencement_date" do
        tp = build(:tenancy_party, tenancy: tenancy, party: party, effective_from: Date.new(2024, 12, 31), effective_until: Date.new(2025, 12, 31))
        expect(tp).not_to be_valid
        expect(tp.errors[:effective_from]).to include("cannot be before tenancy commencement date (2025-01-01)")
      end

      it "prevents effective_from after tenancy termination_date" do
        tp = build(:tenancy_party, tenancy: tenancy, party: party, effective_from: Date.new(2026, 1, 1), effective_until: Date.new(2026, 12, 31))
        expect(tp).not_to be_valid
        expect(tp.errors[:effective_from]).to include("cannot be after tenancy termination date (2025-12-31)")
      end

      it "requires effective_until on a terminated tenancy" do
        tp = build(:tenancy_party, tenancy: tenancy, party: party, effective_from: Date.new(2025, 1, 1), effective_until: nil)
        expect(tp).not_to be_valid
        expect(tp.errors[:effective_until]).to include("is required for a terminated tenancy")
      end

      it "prevents effective_until after tenancy termination_date" do
        tp = build(:tenancy_party, tenancy: tenancy, party: party, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2026, 1, 1))
        expect(tp).not_to be_valid
        expect(tp.errors[:effective_until]).to include("cannot be after tenancy termination date (2025-12-31)")
      end

      it "allows valid boundaries within tenancy" do
        tp = build(:tenancy_party, tenancy: tenancy, party: party, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 12, 31))
        expect(tp).to be_valid
      end

      it "allows open-ended effective_until on an open-ended tenancy" do
        open_tenancy = create(:tenancy, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
        open_party = create(:party, user: open_tenancy.rentable_unit.property.user)
        tp = build(:tenancy_party, tenancy: open_tenancy, party: open_party, effective_from: Date.new(2025, 1, 1), effective_until: nil)
        expect(tp).to be_valid
      end
    end

    describe "same-role overlap prevention for party on same tenancy" do
      let(:tenancy) { create(:tenancy, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil) }
      let(:party) { create(:party, user: tenancy.rentable_unit.property.user) }

      before do
        create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
      end

      it "prevents overlapping same-role participant" do
        overlapping = build(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: Date.new(2025, 6, 1), effective_until: nil)
        expect(overlapping).not_to be_valid
        expect(overlapping.errors[:base]).to include("Party already has an active participant role for the specified dates")
      end

      it "allows sequential non-overlapping same-role participant" do
        next_period = build(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: Date.new(2025, 7, 1), effective_until: nil)
        expect(next_period).to be_valid
      end
    end

    describe "owner validation" do
      let(:other_user) { create(:user) }
      let(:other_party) { create(:party, user: other_user) }
      let(:tenancy) { create(:tenancy) }

      it "validates that party belongs to the same user as the tenancy" do
        tp = build(:tenancy_party, tenancy: tenancy, party: other_party)
        expect(tp).not_to be_valid
        expect(tp.errors[:party]).to include("must belong to the same user as the tenancy")
      end
    end

    describe "#active?" do
      let(:tenancy) { create(:tenancy) }
      let(:party) { create(:party, user: tenancy.rentable_unit.property.user) }

      it "returns false when effective_from is nil" do
        tp = build(:tenancy_party, tenancy: tenancy, party: party, effective_from: nil)
        expect(tp.active?).to be false
      end

      it "evaluates active state with date and hash fallback" do
        tp = build(:tenancy_party, tenancy: tenancy, party: party, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
        expect(tp.active?(Date.new(2025, 3, 1))).to be true
        expect(tp.active?(Date.new(2024, 12, 31))).to be false
        expect(tp.active?(Date.new(2025, 7, 1))).to be false
        expect(tp.active?(as_of: { fallback: true })).to be_in([ true, false ])
      end
    end
  end

  describe "#accounting_user" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil) }
    let(:party) { create(:party, user: user) }
    let(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: Date.new(2025, 1, 1)) }

    it "returns the user owning the property" do
      expect(tenancy_party.accounting_user).to eq(user)
    end

    it "returns nil when tenancy is absent" do
      orphan = build(:tenancy_party, tenancy: nil, party: party)
      expect(orphan.accounting_user).to be_nil
    end
  end
end
