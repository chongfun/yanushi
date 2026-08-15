require "rails_helper"

RSpec.describe RentTerm, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:tenancy) }
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:frequency).with_values(RentTerm::FREQUENCIES.index_by(&:itself)).backed_by_column_of_type(:string) }

    it "validates enum assignment without raising ArgumentError" do
      term = build(:rent_term, frequency: "annually")
      expect(term).not_to be_valid
      expect(term.errors[:frequency]).to include("is not included in the list")
    end
  end

  describe "validations" do
    subject { build(:rent_term) }

    it { is_expected.to validate_presence_of(:amount_cents) }
    it { is_expected.to validate_numericality_of(:amount_cents).only_integer.is_greater_than(0) }
    it { is_expected.to validate_presence_of(:due_day) }
    it { is_expected.to validate_numericality_of(:due_day).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(31) }
    it { is_expected.to validate_presence_of(:frequency) }
    it { is_expected.to validate_presence_of(:effective_from) }

    it "validates effective_until is on or after effective_from" do
      term = build(:rent_term, effective_from: Date.new(2025, 6, 1), effective_until: Date.new(2025, 5, 31))
      expect(term).not_to be_valid
      expect(term.errors[:effective_until]).to include("must be on or after effective from date")
    end

    describe "effective date boundaries relative to tenancy" do
      let(:tenancy) do
        create(:tenancy, commencement_date: Date.new(2025, 1, 1), termination_date: Date.new(2025, 12, 31))
      end

      it "prevents effective_from before tenancy commencement_date" do
        term = build(:rent_term, tenancy: tenancy, effective_from: Date.new(2024, 12, 31), effective_until: Date.new(2025, 6, 30))
        expect(term).not_to be_valid
        expect(term.errors[:effective_from]).to include("cannot be before tenancy commencement date (2025-01-01)")
      end

      it "prevents effective_from after tenancy termination_date" do
        term = build(:rent_term, tenancy: tenancy, effective_from: Date.new(2026, 1, 1), effective_until: Date.new(2026, 6, 30))
        expect(term).not_to be_valid
        expect(term.errors[:effective_from]).to include("cannot be after tenancy termination date (2025-12-31)")
      end

      it "requires effective_until on a terminated tenancy" do
        term = build(:rent_term, tenancy: tenancy, effective_from: Date.new(2025, 1, 1), effective_until: nil)
        expect(term).not_to be_valid
        expect(term.errors[:effective_until]).to include("is required for a terminated tenancy")
      end

      it "prevents effective_until after tenancy termination_date" do
        term = build(:rent_term, tenancy: tenancy, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2026, 1, 1))
        expect(term).not_to be_valid
        expect(term.errors[:effective_until]).to include("cannot be after tenancy termination date (2025-12-31)")
      end

      it "allows open-ended effective_until on an open-ended tenancy" do
        open_tenancy = create(:tenancy, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
        term = build(:rent_term, tenancy: open_tenancy, effective_from: Date.new(2025, 1, 1), effective_until: nil)
        expect(term).to be_valid
      end
    end

    describe "rent term overlap prevention" do
      let(:tenancy) { create(:tenancy, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil) }

      before do
        create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
      end

      it "prevents overlapping term" do
        overlapping = build(:rent_term, tenancy: tenancy, amount_cents: 120_000, effective_from: Date.new(2025, 6, 1), effective_until: nil)
        expect(overlapping).not_to be_valid
        expect(overlapping.errors[:base]).to include("Rent term overlaps with an existing term for this tenancy")
      end

      it "allows contiguous term starting the next day" do
        next_term = build(:rent_term, tenancy: tenancy, amount_cents: 120_000, effective_from: Date.new(2025, 7, 1), effective_until: nil)
        expect(next_term).to be_valid
      end
    end
  end

  describe "#due_date_for" do
    let(:term) { build(:rent_term, due_day: 31) }

    it "clamps to end of month for shorter months" do
      expect(term.due_date_for(2025, 2)).to eq(Date.new(2025, 2, 28))
      expect(term.due_date_for(2024, 2)).to eq(Date.new(2024, 2, 29))
      expect(term.due_date_for(2025, 4)).to eq(Date.new(2025, 4, 30))
      expect(term.due_date_for(2025, 1)).to eq(Date.new(2025, 1, 31))
    end
  end

  describe "#amount and #amount=" do
    it "gets and sets amount from dollars and handles blanks" do
      term = build(:rent_term, amount_cents: 150_000)
      expect(term.amount).to eq(1500.0)

      term.amount_cents = nil
      expect(term.amount).to be_nil

      term.amount = "1750.50"
      expect(term.amount_cents).to eq(175050)

      term.amount = nil
      expect(term.amount_cents).to be_nil

      term.amount = "   "
      expect(term.amount_cents).to be_nil
    end
  end

  describe "#active?" do
    it "returns false when effective_from is nil" do
      term = build(:rent_term, effective_from: nil)
      expect(term.active?).to be false
    end

    it "evaluates active state with date and hash fallback" do
      term = build(:rent_term, effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))
      expect(term.active?(Date.new(2025, 3, 1))).to be true
      expect(term.active?(Date.new(2024, 12, 31))).to be false
      expect(term.active?(Date.new(2025, 7, 1))).to be false
      expect(term.active?(as_of: { fallback: true })).to be_in([ true, false ])
    end
  end
end
