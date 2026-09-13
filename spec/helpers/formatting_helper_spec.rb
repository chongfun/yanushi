require "rails_helper"

RSpec.describe FormattingHelper, type: :helper do
  describe "#format_money_cents" do
    it "formats positive cents to dollars with cents" do
      expect(helper.format_money_cents(240000)).to eq("$2,400.00")
      expect(helper.format_money_cents(35000)).to eq("$350.00")
    end

    it "formats zero cents" do
      expect(helper.format_money_cents(0)).to eq("$0.00")
    end

    it "handles nil gracefully" do
      expect(helper.format_money_cents(nil)).to eq("$0.00")
    end
  end

  describe "#signed_money_cents" do
    it "formats negative cents with a Unicode minus sign" do
      expect(helper.signed_money_cents(-200000)).to eq("\u2212$2,000.00")
    end

    it "formats positive cents without a sign by default" do
      expect(helper.signed_money_cents(200000)).to eq("$2,000.00")
    end

    it "formats positive cents with a plus sign when plus: true" do
      expect(helper.signed_money_cents(200000, plus: true)).to eq("+$2,000.00")
    end

    it "formats zero cents" do
      expect(helper.signed_money_cents(0)).to eq("$0.00")
    end

    it "handles nil gracefully" do
      expect(helper.signed_money_cents(nil)).to eq("$0.00")
    end
  end

  describe "#balance_phrase_cents" do
    it "formats positive balance as 'due'" do
      expect(helper.balance_phrase_cents(35000)).to eq("$350.00 due")
    end

    it "formats negative balance as 'credit'" do
      expect(helper.balance_phrase_cents(-8000)).to eq("$80.00 credit")
    end

    it "formats zero balance as 'Settled'" do
      expect(helper.balance_phrase_cents(0)).to eq("Settled")
    end

    it "handles nil balance as 'Settled'" do
      expect(helper.balance_phrase_cents(nil)).to eq("Settled")
    end
  end
end
