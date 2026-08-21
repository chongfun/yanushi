require "rails_helper"

RSpec.describe Tenancy, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:rentable_unit) }
    it { is_expected.to have_one(:property).through(:rentable_unit) }
    it { is_expected.to have_many(:tenancy_parties).dependent(:destroy) }
    it { is_expected.to have_many(:parties).through(:tenancy_parties) }
    it { is_expected.to have_many(:rent_terms).dependent(:destroy) }
    it { is_expected.to have_many(:scheduled_rents).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:tenant_payments).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:tenant_charges).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:payment_ingestions).dependent(:nullify) }
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:agreement_type).with_values(Tenancy::AGREEMENT_TYPES.index_by(&:itself)).backed_by_column_of_type(:string) }

    it "validates enum assignment without raising ArgumentError" do
      tenancy = build(:tenancy, agreement_type: "invalid_agreement")
      expect(tenancy).not_to be_valid
      expect(tenancy.errors[:agreement_type]).to include("is not included in the list")
    end
  end

  describe "validations" do
    subject { build(:tenancy) }

    it { is_expected.to validate_presence_of(:commencement_date) }
    it { is_expected.to validate_presence_of(:agreement_type) }
    it { is_expected.to validate_numericality_of(:late_period_days).only_integer.is_greater_than_or_equal_to(0) }

    it "validates termination_date is on or after commencement_date" do
      tenancy = build(:tenancy, commencement_date: Date.new(2025, 1, 1), termination_date: Date.new(2024, 12, 31))
      expect(tenancy).not_to be_valid
      expect(tenancy.errors[:termination_date]).to include("must be on or after commencement date")
    end

    it "prevents creating a tenancy on a deactivated unit" do
      inactive_unit = create(:rentable_unit, active: false)
      tenancy = build(:tenancy, rentable_unit: inactive_unit)
      expect(tenancy).not_to be_valid
      expect(tenancy.errors[:rentable_unit]).to include("is deactivated and cannot receive new tenancies")
    end

    describe "same-unit tenancy overlap prevention" do
      let(:unit) { create(:rentable_unit) }
      let!(:existing_tenancy) do
        create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2025, 1, 1), termination_date: Date.new(2025, 12, 31))
      end

      it "prevents overlapping tenancy with defined termination" do
        overlapping = build(:tenancy, rentable_unit: unit, commencement_date: Date.new(2025, 6, 1), termination_date: Date.new(2026, 5, 31))
        expect(overlapping).not_to be_valid
        expect(overlapping.errors[:base]).to include("An active tenancy already exists for this unit during the specified dates")
      end

      it "prevents open-ended tenancy overlapping with existing tenancy" do
        overlapping = build(:tenancy, rentable_unit: unit, commencement_date: Date.new(2025, 6, 1), termination_date: nil)
        expect(overlapping).not_to be_valid
        expect(overlapping.errors[:base]).to include("An active tenancy already exists for this unit during the specified dates")
      end

      it "allows non-overlapping tenancy on the same unit" do
        after_tenancy = build(:tenancy, rentable_unit: unit, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))
        expect(after_tenancy).to be_valid
      end

      it "allows overlapping dates on a different unit" do
        other_unit = create(:rentable_unit, property: unit.property, name: "Unit B")
        other_tenancy = build(:tenancy, rentable_unit: other_unit, commencement_date: Date.new(2025, 6, 1), termination_date: Date.new(2026, 5, 31))
        expect(other_tenancy).to be_valid
      end
    end
  end

  describe "scopes and helper methods" do
    let(:unit) { create(:rentable_unit) }

    describe ".active" do
      it "returns tenancies that are ongoing or encompass current date" do
        active1 = create(:tenancy, rentable_unit: unit, commencement_date: 1.month.ago, termination_date: 1.month.from_now)
        expect(Tenancy.active).to include(active1)
      end

      it "excludes past or future tenancies" do
        past = create(:tenancy, rentable_unit: unit, commencement_date: 1.year.ago, termination_date: 6.months.ago)
        expect(Tenancy.active).not_to include(past)
      end
    end

    describe "#active?" do
      it "returns false when commencement date is nil" do
        tenancy = build(:tenancy, commencement_date: nil)
        expect(tenancy.active?).to be false
      end

      it "returns true for open-ended month-to-month tenancies" do
        tenancy = create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: 1.month.ago, termination_date: nil)
        expect(tenancy.active?).to be true
        expect(tenancy.active?(as_of: { fallback: true })).to be true
      end
    end

    describe "#continuous_tenant_coverage?" do
      let(:party1) { create(:party, user: unit.property.user) }
      let(:party2) { create(:party, user: unit.property.user) }

      context "with a fixed term tenancy" do
        let(:tenancy) do
          create(:tenancy,
            rentable_unit: unit,
            agreement_type: "fixed_term",
            commencement_date: Date.new(2025, 1, 1),
            termination_date: Date.new(2025, 12, 31)
          )
        end

        it "returns true when a single tenant covers the whole term" do
          create(:tenancy_party, tenancy: tenancy, party: party1, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 12, 31))
          expect(tenancy.continuous_tenant_coverage?).to be true
        end

        it "returns true when multiple sequential tenants cover the term" do
          create(:tenancy_party, tenancy: tenancy, party: party1, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
          create(:tenancy_party, tenancy: tenancy, party: party2, role: "tenant", effective_from: Date.new(2025, 7, 1), effective_until: Date.new(2025, 12, 31))
          expect(tenancy.continuous_tenant_coverage?).to be true
        end

        it "returns false when there is a gap between tenants" do
          create(:tenancy_party, tenancy: tenancy, party: party1, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
          create(:tenancy_party, tenancy: tenancy, party: party2, role: "tenant", effective_from: Date.new(2025, 8, 1), effective_until: Date.new(2025, 12, 31))
          expect(tenancy.continuous_tenant_coverage?).to be false
        end

        it "returns false when the only tenant starts after commencement date" do
          create(:tenancy_party, tenancy: tenancy, party: party1, role: "tenant", effective_from: Date.new(2025, 2, 1), effective_until: Date.new(2025, 12, 31))
          expect(tenancy.continuous_tenant_coverage?).to be false
        end

        it "returns false when the tenant ends before termination date" do
          create(:tenancy_party, tenancy: tenancy, party: party1, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 11, 30))
          expect(tenancy.continuous_tenant_coverage?).to be false
        end

        it "returns false when there are only non-tenant participants" do
          create(:tenancy_party, tenancy: tenancy, party: party1, role: "guarantor", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 12, 31))
          expect(tenancy.continuous_tenant_coverage?).to be false
        end
      end

      context "with an open-ended tenancy" do
        let(:tenancy) do
          create(:tenancy,
            rentable_unit: unit,
            agreement_type: "month_to_month",
            commencement_date: Date.new(2025, 1, 1),
            termination_date: nil
          )
        end

        it "returns true when tenant has open-ended coverage" do
          create(:tenancy_party, tenancy: tenancy, party: party1, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: nil)
          expect(tenancy.continuous_tenant_coverage?).to be true
        end

        it "returns false when tenant has bounded coverage without open-ended successor" do
          create(:tenancy_party, tenancy: tenancy, party: party1, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 12, 31))
          expect(tenancy.continuous_tenant_coverage?).to be false
        end

        it "returns false when commencement_date is nil or no tenant candidates" do
          tenancy.commencement_date = nil
          expect(tenancy.continuous_tenant_coverage?).to be false
        end

        it "handles candidate parties with nil effective_from or redundant intervals" do
          tp1 = build(:tenancy_party, tenancy: tenancy, party: party1, role: "tenant", effective_from: nil, effective_until: nil)
          expect(tenancy.continuous_tenant_coverage?([ tp1 ])).to be false

          tp_valid = build(:tenancy_party, tenancy: tenancy, party: party1, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: nil)
          tp_redundant = build(:tenancy_party, tenancy: tenancy, party: party2, role: "tenant", effective_from: Date.new(2025, 2, 1), effective_until: Date.new(2025, 3, 1))
          expect(tenancy.continuous_tenant_coverage?([ tp_valid, tp_redundant ])).to be true
        end
      end
    end

    describe "#current_rent_term" do
      let(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil) }

      it "returns the term active on the specified date" do
        term1 = create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
        term2 = create(:rent_term, tenancy: tenancy, amount_cents: 120_000, effective_from: Date.new(2025, 7, 1), effective_until: nil)

        expect(tenancy.current_rent_term(Date.new(2025, 3, 1))).to eq(term1)
        expect(tenancy.current_rent_term(Date.new(2025, 8, 1))).to eq(term2)
        expect(tenancy.current_rent_term(as_of: { fallback: true })).to eq(term2)
      end

      it "returns nil when there is a gap between terms" do
        create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
        create(:rent_term, tenancy: tenancy, amount_cents: 120_000, effective_from: Date.new(2025, 8, 1), effective_until: nil)

        expect(tenancy.current_rent_term(Date.new(2025, 7, 15))).to be_nil
      end

      it "returns nil when date is before first rent term" do
        create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
        expect(tenancy.current_rent_term(Date.new(2024, 1, 1))).to be_nil
      end
    end

    describe "#most_recent_rent_term" do
      let(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil) }

      it "returns the term with latest effective_from date" do
        create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
        term2 = create(:rent_term, tenancy: tenancy, amount_cents: 120_000, effective_from: Date.new(2025, 8, 1), effective_until: nil)

        expect(tenancy.most_recent_rent_term).to eq(term2)
      end
    end

    describe "#financial_history? and current_balance" do
      let(:tenancy) { create(:tenancy, rentable_unit: unit) }

      it "identifies presence of financial history" do
        expect(tenancy.financial_history?).to be false
        create(:tenant_payment, tenancy: tenancy, amount: 1500.0, payment_date: Date.current)
        expect(tenancy.financial_history?).to be true
      end

      it "computes balance via Tenancies::BalanceQuery" do
        create(:tenant_payment, tenancy: tenancy, amount: 1500.0, payment_date: Date.current)
        create(:scheduled_rent, tenancy: tenancy, amount: 1000.0, due_date: Date.current)
        create(:tenant_charge, tenancy: tenancy, amount: 200.0, charge_date: Date.current)

        expect(tenancy.current_balance).to eq(300.0)
      end
    end

    describe "#accounting_user" do
      let(:tenancy) { create(:tenancy, rentable_unit: unit) }

      it "returns the user owning the property" do
        expect(tenancy.accounting_user).to eq(unit.property.user)
      end

      it "returns nil when rentable_unit is absent" do
        orphan = build(:tenancy, rentable_unit: nil)
        expect(orphan.accounting_user).to be_nil
      end
    end
  end
end
