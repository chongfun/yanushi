require "rails_helper"

RSpec.describe TaxReporting::TaxYear do
  describe ".parse" do
    it "parses valid 4-digit integer years" do
      result = described_class.parse(2025)
      expect(result).to be_a(described_class)
      expect(result.to_i).to eq(2025)
      expect(result.to_s).to eq("2025")
    end

    it "parses valid 4-digit string years and trims whitespace" do
      result = described_class.parse("  2024 \n")
      expect(result).to be_a(described_class)
      expect(result.to_i).to eq(2024)
    end

    it "defaults to current year when nil or blank" do
      expect(described_class.parse(nil).to_i).to eq(Date.current.year)
      expect(described_class.parse("").to_i).to eq(Date.current.year)
      expect(described_class.parse("  ").to_i).to eq(Date.current.year)
    end

    it "returns nil for malformed non-year strings" do
      expect(described_class.parse("garbage")).to be_nil
      expect(described_class.parse("202x")).to be_nil
      expect(described_class.parse("0")).to be_nil
      expect(described_class.parse("-2025")).to be_nil
      expect(described_class.parse("2025-01-01")).to be_nil
      expect(described_class.parse("99999")).to be_nil
      expect(described_class.parse("12")).to be_nil
    end

    it "returns nil for years outside the supported 1901..2099 boundary" do
      expect(described_class.parse(1899)).to be_nil
      expect(described_class.parse(2101)).to be_nil
    end
  end

  describe ".parse!" do
    it "returns parsed TaxYear when valid" do
      expect(described_class.parse!("2025").to_i).to eq(2025)
    end

    it "raises InvalidTaxYearError when invalid" do
      expect {
        described_class.parse!("garbage")
      }.to raise_error(TaxReporting::InvalidTaxYearError, /Invalid tax year/)
    end
  end

  describe "equality" do
    it "equals other TaxYear with same integer value" do
      y1 = described_class.new(2025)
      y2 = described_class.new("2025")
      expect(y1).to eq(y2)
      expect(y1).to eq(2025)
      expect(y1).to eq("2025")
    end
  end
end
