require "rails_helper"

RSpec.describe ImportedTransactions::Parsers::Base do
  let(:base_parser) { described_class.new }

  describe "#clean_name" do
    it "removes non-word characters except hyphens and apostrophes" do
      expect(base_parser.send(:clean_name, "  John Doe (Tenant) #123  ")).to eq("John Doe Tenant 123")
      expect(base_parser.send(:clean_name, nil)).to be_nil
      expect(base_parser.send(:clean_name, "   ")).to be_nil
    end
  end

  describe "#parse_amount_cents" do
    it "parses dollar amount string to integer cents" do
      expect(base_parser.send(:parse_amount_cents, "Amount: $1,250.50 paid")).to eq(125_050)
      expect(base_parser.send(:parse_amount_cents, "No amounts here")).to be_nil
    end
  end

  describe "#parse_date" do
    it "parses valid date strings and rescues invalid date strings" do
      expect(base_parser.send(:parse_date, "Mar 24, 2026")).to eq(Date.new(2026, 3, 24))
      expect(base_parser.send(:parse_date, "Not a real date")).to be_nil
      expect(base_parser.send(:parse_date, nil)).to be_nil
    end
  end

  describe "#parse" do
    it "raises NotImplementedError when not overridden" do
      expect { base_parser.parse("test") }.to raise_error(NotImplementedError)
    end
  end
end
