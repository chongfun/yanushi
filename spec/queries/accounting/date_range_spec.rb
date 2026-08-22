require "rails_helper"

RSpec.describe Accounting::DateRange do
  describe ".parse and .new" do
    it "parses year into full calendar year range" do
      dr = described_class.parse(year: 2026)
      expect(dr).to be_valid
      expect(dr.from).to eq(Date.new(2026, 1, 1))
      expect(dr.through).to eq(Date.new(2026, 12, 31))
      expect(dr.year).to eq(2026)
      expect(dr.range).to eq(Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
    end

    it "parses string year" do
      dr = described_class.parse(year: "2025")
      expect(dr).to be_valid
      expect(dr.from).to eq(Date.new(2025, 1, 1))
      expect(dr.through).to eq(Date.new(2025, 12, 31))
      expect(dr.year).to eq(2025)
    end

    it "parses explicit from and through dates" do
      dr = described_class.parse(from: "2026-03-01", through: "2026-06-30")
      expect(dr).to be_valid
      expect(dr.from).to eq(Date.new(2026, 3, 1))
      expect(dr.through).to eq(Date.new(2026, 6, 30))
      expect(dr.range).to eq(Date.new(2026, 3, 1)..Date.new(2026, 6, 30))
      expect(dr.year).to be_nil
    end

    it "handles Date objects directly" do
      d1 = Date.new(2026, 2, 1)
      d2 = Date.new(2026, 2, 28)
      dr = described_class.new(from: d1, through: d2)
      expect(dr).to be_valid
      expect(dr.from).to eq(d1)
      expect(dr.through).to eq(d2)
    end

    it "handles from only (defaults through to Date.current)" do
      dr = described_class.parse(from: "2026-01-01")
      expect(dr).to be_valid
      expect(dr.from).to eq(Date.new(2026, 1, 1))
      expect(dr.through).to eq(Date.current)
      expect(dr.as_of).to eq(Date.current)
    end

    it "handles explicit range_mode parameter" do
      # range_mode == "year" overrides from/through if present
      dr_year = described_class.parse(range_mode: "year", year: 2025, from: "2026-01-01", through: "2026-12-31")
      expect(dr_year.year).to eq(2025)
      expect(dr_year.from).to eq(Date.new(2025, 1, 1))

      # range_mode == "custom" uses from/through
      dr_custom = described_class.parse(range_mode: "custom", year: 2025, from: "2026-03-01", through: "2026-06-30")
      expect(dr_custom.from).to eq(Date.new(2026, 3, 1))
      expect(dr_custom.through).to eq(Date.new(2026, 6, 30))
    end

    it "handles through only (open-ended lower bound)" do
      dr = described_class.parse(through: "2026-12-31")
      expect(dr).to be_valid
      expect(dr.from).to be_nil
      expect(dr.through).to eq(Date.new(2026, 12, 31))
    end

    it "handles empty inputs by defaulting to current year" do
      dr = described_class.parse({})
      expect(dr).to be_valid
      expect(dr.from).to eq(Date.current.beginning_of_year)
      expect(dr.through).to eq(Date.current.end_of_year)
      expect(dr.year).to eq(Date.current.year)
    end

    it "rejects when from is after through" do
      dr = described_class.parse(from: "2026-12-31", through: "2026-01-01")
      expect(dr).not_to be_valid
      expect(dr.errors).to include("From date cannot be after through date")
    end

    it "rejects invalid date strings" do
      dr = described_class.parse(from: "invalid-date", through: "2026-12-31")
      expect(dr).not_to be_valid
      expect(dr.errors).to include("Invalid from date")
    end

    it "handles nil, non-hash objects, and ActionController parameters" do
      expect(described_class.parse(nil)).to be_valid
      expect(described_class.parse("foo")).to be_valid
      params = ActionController::Parameters.new(year: "2026")
      expect(described_class.parse(params).year).to eq(2026)
    end

    it "returns nil for year on invalid range or single-bound ranges" do
      invalid_dr = described_class.new(from: Date.new(2026, 12, 31), through: Date.new(2026, 1, 1))
      expect(invalid_dr.year).to be_nil

      open_ended_dr = described_class.new(from: nil, through: Date.new(2026, 12, 31))
      expect(open_ended_dr.year).to be_nil

      open_ended_from = described_class.new(from: Date.new(2026, 1, 1), through: nil)
      expect(open_ended_from.year).to be_nil
    end

    it "parses dates from Time objects and handles malformed year inputs" do
      t1 = Time.zone.local(2026, 4, 1, 10, 0, 0)
      t2 = Time.zone.local(2026, 5, 1, 10, 0, 0)
      dr = described_class.parse(from: t1, through: t2)
      expect(dr.from).to eq(Date.new(2026, 4, 1))
      expect(dr.through).to eq(Date.new(2026, 5, 1))

      malformed_year = described_class.parse(year: "99999")
      expect(malformed_year.year).to be_nil
    end
  end
end
