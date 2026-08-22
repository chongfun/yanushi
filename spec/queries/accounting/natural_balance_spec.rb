require "rails_helper"

RSpec.describe Accounting::NaturalBalance do
  describe ".multiplier_for" do
    it "returns 1 for asset and expense accounts" do
      expect(described_class.multiplier_for("asset")).to eq(1)
      expect(described_class.multiplier_for("expense")).to eq(1)
      expect(described_class.multiplier_for(:asset)).to eq(1)
      expect(described_class.multiplier_for(:expense)).to eq(1)
    end

    it "returns -1 for liability, equity, and income accounts" do
      expect(described_class.multiplier_for("liability")).to eq(-1)
      expect(described_class.multiplier_for("equity")).to eq(-1)
      expect(described_class.multiplier_for("income")).to eq(-1)
      expect(described_class.multiplier_for(:liability)).to eq(-1)
      expect(described_class.multiplier_for(:equity)).to eq(-1)
      expect(described_class.multiplier_for(:income)).to eq(-1)
    end

    it "works with Account model instances" do
      asset_acc = build(:account, account_type: "asset")
      liab_acc = build(:account, account_type: "liability")
      inc_acc = build(:account, account_type: "income")

      expect(described_class.multiplier_for(asset_acc)).to eq(1)
      expect(described_class.multiplier_for(liab_acc)).to eq(-1)
      expect(described_class.multiplier_for(inc_acc)).to eq(-1)
    end
  end

  describe ".convert" do
    it "preserves debit balance for assets and expenses" do
      expect(described_class.convert("asset", 50_000)).to eq(50_000)
      expect(described_class.convert("expense", 25_000)).to eq(25_000)
    end

    it "inverts raw negative credit balance to positive natural balance for liabilities, equity, and income" do
      # In the database, a credit of $2,000 is stored as -200_000 cents.
      # Natural balance is positive $2,000.
      expect(described_class.convert("liability", -200_000)).to eq(200_000)
      expect(described_class.convert("income", -150_000)).to eq(150_000)
      expect(described_class.convert("equity", -100_000)).to eq(100_000)
    end

    it "handles zero and nil values" do
      expect(described_class.convert("liability", 0)).to eq(0)
      expect(described_class.convert("liability", nil)).to eq(0)
    end
  end

  describe ".to_raw" do
    it "converts natural balance to raw balance" do
      expect(described_class.to_raw("asset", 50_000)).to eq(50_000)
      expect(described_class.to_raw("liability", 200_000)).to eq(-200_000)
      expect(described_class.to_raw("liability", nil)).to eq(0)
    end
  end

  describe ".debit_normal? and .credit_normal?" do
    it "correctly identifies normal debit and credit accounts" do
      expect(described_class.debit_normal?("asset")).to be true
      expect(described_class.debit_normal?("expense")).to be true
      expect(described_class.debit_normal?("liability")).to be false

      expect(described_class.credit_normal?("liability")).to be true
      expect(described_class.credit_normal?("income")).to be true
      expect(described_class.credit_normal?("asset")).to be false
    end
  end
end
