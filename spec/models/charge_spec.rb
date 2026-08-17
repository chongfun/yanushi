require "rails_helper"

RSpec.describe Charge, type: :model do
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

  describe "associations" do
    it { is_expected.to belong_to(:tenancy) }
    it { is_expected.to belong_to(:rent_term).optional }
    it { is_expected.to belong_to(:source_expense).class_name("Expense").optional }
    it { is_expected.to belong_to(:superseded_by).class_name("Charge").optional }
    it { is_expected.to have_one(:superseded_charge).class_name("Charge").with_foreign_key(:superseded_by_id) }
    it { is_expected.to have_many(:journal_entries).dependent(:restrict_with_error) }
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:charge_kind).with_values(Charge::CHARGE_KINDS.index_by(&:itself)).backed_by_column_of_type(:string) }
  end

  describe "validations" do
    subject { build(:charge, tenancy: tenancy) }

    it { is_expected.to validate_presence_of(:amount_cents) }
    it { is_expected.to validate_numericality_of(:amount_cents).only_integer.is_greater_than(0) }
    it { is_expected.to validate_presence_of(:charge_kind) }
    it { is_expected.to validate_presence_of(:charge_date) }
    it { is_expected.to validate_presence_of(:due_on) }

    it "validates service_period_end is on or after service_period_start" do
      charge = build(:charge,
        tenancy: tenancy,
        service_period_start: Date.new(2026, 5, 1),
        service_period_end: Date.new(2026, 4, 30)
      )
      expect(charge).not_to be_valid
      expect(charge.errors[:service_period_end]).to include("cannot be before service period start")
    end
  end

  describe "#amount and #amount=" do
    it "converts amount_cents to dollars" do
      charge = build(:charge, amount_cents: 125_050)
      expect(charge.amount).to eq(1250.50)
    end

    it "returns nil if amount_cents is nil" do
      charge = build(:charge, amount_cents: nil)
      expect(charge.amount).to be_nil
    end

    it "sets amount_cents from dollar strings using BigDecimal" do
      charge = build(:charge)
      charge.amount = "1250.50"
      expect(charge.amount_cents).to eq(125_050)

      charge.amount = 300
      expect(charge.amount_cents).to eq(30_000)

      charge.amount = ""
      expect(charge.amount_cents).to eq(0)

      charge.amount = nil
      expect(charge.amount_cents).to eq(0)
    end
  end

  describe "kind-specific invariants" do
    context "rent charge" do
      let!(:rent_term) do
        create(:rent_term,
          tenancy: tenancy,
          amount_cents: 200_000,
          effective_from: Date.new(2026, 1, 1),
          effective_until: Date.new(2026, 12, 31)
        )
      end

      it "is valid with required rent fields within bounds" do
        charge = build(:charge, :rent_charge,
          tenancy: tenancy,
          rent_term: rent_term,
          service_period_start: Date.new(2026, 5, 1),
          service_period_end: Date.new(2026, 5, 31)
        )
        expect(charge).to be_valid
      end

      it "requires rent_term_id" do
        charge = build(:charge,
          charge_kind: "rent",
          tenancy: tenancy,
          rent_term: nil,
          service_period_start: Date.new(2026, 5, 1),
          service_period_end: Date.new(2026, 5, 31)
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:rent_term]).to include("is required for rent charge")
      end

      it "requires service_period_start and service_period_end" do
        charge = build(:charge,
          charge_kind: "rent",
          tenancy: tenancy,
          rent_term: rent_term,
          service_period_start: nil,
          service_period_end: nil
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:service_period_start]).to include("is required for rent charge")
        expect(charge.errors[:service_period_end]).to include("is required for rent charge")
      end

      it "requires source_expense to be nil" do
        expense = create(:expense, property: property)
        charge = build(:charge, :rent_charge,
          tenancy: tenancy,
          rent_term: rent_term,
          source_expense: expense,
          service_period_start: Date.new(2026, 5, 1),
          service_period_end: Date.new(2026, 5, 31)
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:source_expense]).to include("must be blank for rent charge")
      end

      it "requires rent_term to belong to the same tenancy" do
        other_unit = create(:rentable_unit, property: property, name: "Unit B")
        other_tenancy = create(:tenancy, rentable_unit: other_unit, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))
        other_term = create(:rent_term, tenancy: other_tenancy, amount_cents: 100_000, effective_from: Date.new(2026, 1, 1), effective_until: Date.new(2026, 12, 31))
        charge = build(:charge,
          charge_kind: "rent",
          tenancy: tenancy,
          rent_term: other_term,
          service_period_start: Date.new(2026, 5, 1),
          service_period_end: Date.new(2026, 5, 31)
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:rent_term]).to include("must belong to the same tenancy")
      end

      it "validates service period within tenancy bounds" do
        charge = build(:charge, :rent_charge,
          tenancy: tenancy,
          rent_term: rent_term,
          service_period_start: Date.new(2025, 12, 1),
          service_period_end: Date.new(2025, 12, 31)
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:service_period_start]).to include("cannot be before tenancy commencement date")

        charge2 = build(:charge, :rent_charge,
          tenancy: tenancy,
          rent_term: rent_term,
          service_period_start: Date.new(2027, 1, 1),
          service_period_end: Date.new(2027, 1, 31)
        )
        expect(charge2).not_to be_valid
        expect(charge2.errors[:service_period_end]).to include("cannot be after tenancy termination date")
      end

      it "validates service period within rent term bounds" do
        other_unit = create(:rentable_unit, property: property, name: "Unit C")
        bounded_tenancy = create(:tenancy, rentable_unit: other_unit, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))
        bounded_term = create(:rent_term,
          tenancy: bounded_tenancy,
          amount_cents: 220_000,
          effective_from: Date.new(2026, 6, 1),
          effective_until: Date.new(2026, 8, 31)
        )
        charge = build(:charge, :rent_charge,
          tenancy: bounded_tenancy,
          rent_term: bounded_term,
          service_period_start: Date.new(2026, 5, 1),
          service_period_end: Date.new(2026, 5, 31)
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:service_period_start]).to include("cannot be before rent term effective from date")

        charge2 = build(:charge, :rent_charge,
          tenancy: bounded_tenancy,
          rent_term: bounded_term,
          service_period_start: Date.new(2026, 9, 1),
          service_period_end: Date.new(2026, 9, 30)
        )
        expect(charge2).not_to be_valid
        expect(charge2.errors[:service_period_end]).to include("cannot be after rent term effective until date")
      end
    end

    context "reimbursement charge" do
      let(:expense) { create(:expense, property: property) }

      it "is valid with linked expense from same property and user" do
        charge = build(:charge,
          charge_kind: "reimbursement",
          tenancy: tenancy,
          source_expense: expense
        )
        expect(charge).to be_valid
      end

      it "requires source_expense" do
        charge = build(:charge,
          charge_kind: "reimbursement",
          tenancy: tenancy,
          source_expense: nil
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:source_expense]).to include("is required for reimbursement charge")
      end

      it "rejects rent_term or service_period on reimbursement" do
        charge = build(:charge,
          charge_kind: "reimbursement",
          tenancy: tenancy,
          source_expense: expense,
          service_period_start: Date.new(2026, 5, 1)
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:service_period_start]).to include("must be blank for reimbursement charge")
      end

      it "rejects source_expense belonging to a different property" do
        other_property = create(:property, user: user)
        other_expense = create(:expense, property: other_property)
        charge = build(:charge,
          charge_kind: "reimbursement",
          tenancy: tenancy,
          source_expense: other_expense
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:source_expense]).to include("must belong to the same property as the tenancy")
      end

      it "rejects source_expense belonging to a different user" do
        other_user = create(:user)
        other_property = create(:property, user: other_user)
        other_expense = create(:expense, property: other_property)
        charge = build(:charge,
          charge_kind: "reimbursement",
          tenancy: tenancy,
          source_expense: other_expense
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:source_expense]).to include("must belong to the same property as the tenancy")
      end

      it "rejects source_expense scoped to a different unit in the same property" do
        unit_b = create(:rentable_unit, property: property, name: "Unit B")
        unit_b_expense = create(:expense, property: property, rentable_unit: unit_b)
        charge = build(:charge,
          charge_kind: "reimbursement",
          tenancy: tenancy,
          source_expense: unit_b_expense
        )
        expect(charge).not_to be_valid
        expect(charge.errors[:source_expense]).to include("must be scoped to the same unit as the tenancy")
      end

      it "allows property-wide source_expense (no unit) for any tenancy on the property" do
        property_wide_expense = create(:expense, property: property, rentable_unit: nil)
        charge = build(:charge,
          charge_kind: "reimbursement",
          tenancy: tenancy,
          source_expense: property_wide_expense
        )
        expect(charge).to be_valid
      end
    end

    context "late_fee and other charges" do
      it "is valid without rent_term or source_expense" do
        late_fee = build(:charge, :late_fee_charge, tenancy: tenancy)
        expect(late_fee).to be_valid

        other = build(:charge, :other_charge, tenancy: tenancy)
        expect(other).to be_valid
      end

      it "rejects source_expense on late_fee or other" do
        expense = create(:expense, property: property)
        late_fee = build(:charge, :late_fee_charge, tenancy: tenancy, source_expense: expense)
        expect(late_fee).not_to be_valid
        expect(late_fee.errors[:source_expense]).to include("must be blank for late fee charge")
      end
    end
  end

  describe "immutability on posted charges" do
    let!(:charge) do
      create(:charge, :other_charge,
        tenancy: tenancy,
        amount_cents: 5000,
        charge_date: Date.new(2026, 5, 1),
        due_on: Date.new(2026, 5, 1),
        posted_at: Time.current
      )
    end

    it "prevents updating financial attributes once posted" do
      charge.amount_cents = 6000
      expect(charge).not_to be_valid
      expect(charge.errors[:amount_cents]).to include("cannot be modified after charge is posted")

      charge.reload
      charge.charge_date = Date.new(2026, 5, 2)
      expect(charge).not_to be_valid
      expect(charge.errors[:charge_date]).to include("cannot be modified after charge is posted")

      charge.reload
      charge.charge_kind = "late_fee"
      expect(charge).not_to be_valid
      expect(charge.errors[:charge_kind]).to include("cannot be modified after charge is posted")
    end

    it "prevents updating voided_at, posted_at, and superseded_by_id directly on posted charges" do
      superseding_charge = create(:charge, :other_charge, tenancy: tenancy)
      charge.voided_at = Time.current
      expect(charge).not_to be_valid
      expect(charge.errors[:voided_at]).to include("cannot be modified directly; use Charges::VoidService")

      charge.reload
      charge.posted_at = nil
      expect(charge).not_to be_valid
      expect(charge.errors[:posted_at]).to include("cannot be modified once posted")

      charge.reload
      charge.superseded_by = superseding_charge
      expect(charge).not_to be_valid
      expect(charge.errors[:superseded_by_id]).to include("cannot be modified directly")
    end

    it "prevents destroying a posted charge" do
      expect { charge.destroy }.not_to change(described_class, :count)
      expect(charge.errors[:base]).to include("Cannot delete a posted charge. Void the charge instead.")
    end

    it "allows destroying an unposted charge" do
      unposted = create(:charge, :other_charge, tenancy: tenancy, posted_at: nil)
      expect { unposted.destroy }.to change(described_class, :count).by(-1)
    end

    it "determines lifecycle_status correctly with superseded taking precedence over voided" do
      rep = create(:charge, :other_charge, tenancy: tenancy)
      superseded_c = create(:charge, :other_charge, tenancy: tenancy, posted_at: Time.current, voided_at: Time.current, superseded_by: rep)
      voided_c = create(:charge, :other_charge, tenancy: tenancy, posted_at: Time.current, voided_at: Time.current)
      active_c = create(:charge, :other_charge, tenancy: tenancy, posted_at: Time.current, voided_at: nil)
      draft_c = create(:charge, :other_charge, tenancy: tenancy, posted_at: nil, voided_at: nil)

      expect(superseded_c.lifecycle_status).to eq(:superseded)
      expect(superseded_c.superseded?).to be true
      expect(voided_c.lifecycle_status).to eq(:voided)
      expect(voided_c.superseded?).to be false
      expect(active_c.lifecycle_status).to eq(:posted)
      expect(draft_c.lifecycle_status).to eq(:draft)
    end
  end

  describe "#accounting_user" do
    it "returns the user owning the tenancy property" do
      charge = build(:charge, tenancy: tenancy)
      expect(charge.accounting_user).to eq(user)
    end

    it "returns nil if tenancy is absent" do
      charge = build(:charge, tenancy: nil)
      expect(charge.accounting_user).to be_nil
    end
  end

  describe "scopes" do
    let!(:active_charge) { create(:charge, :other_charge, tenancy: tenancy, voided_at: nil, posted_at: Time.current) }
    let!(:voided_charge) { create(:charge, :other_charge, :voided_charge, tenancy: tenancy, posted_at: Time.current) }
    let!(:unposted_charge) { create(:charge, :other_charge, tenancy: tenancy, posted_at: nil) }

    it "filters active and voided charges" do
      expect(described_class.active).to include(active_charge, unposted_charge)
      expect(described_class.active).not_to include(voided_charge)

      expect(described_class.voided).to include(voided_charge)
      expect(described_class.voided).not_to include(active_charge)

      expect(described_class.posted).to include(active_charge, voided_charge)
      expect(described_class.posted).not_to include(unposted_charge)
    end
  end
end
