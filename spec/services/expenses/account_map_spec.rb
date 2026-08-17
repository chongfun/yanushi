require "rails_helper"

RSpec.describe Expenses::AccountMap do
  describe ".account_key_for" do
    it "maps valid expense kinds to their corresponding system account keys" do
      expect(described_class.account_key_for("advertising")).to eq("expense_advertising")
      expect(described_class.account_key_for("auto_and_travel")).to eq("expense_auto_travel")
      expect(described_class.account_key_for("cleaning_and_maintenance")).to eq("expense_cleaning_maintenance")
      expect(described_class.account_key_for("commissions")).to eq("expense_commissions")
      expect(described_class.account_key_for("insurance")).to eq("expense_insurance")
      expect(described_class.account_key_for("legal_and_professional")).to eq("expense_legal_professional")
      expect(described_class.account_key_for("management")).to eq("expense_management")
      expect(described_class.account_key_for("mortgage_interest")).to eq("expense_mortgage_interest")
      expect(described_class.account_key_for("other_interest")).to eq("expense_other_interest")
      expect(described_class.account_key_for("repairs")).to eq("expense_repairs")
      expect(described_class.account_key_for("supplies")).to eq("expense_supplies")
      expect(described_class.account_key_for("taxes")).to eq("expense_taxes")
      expect(described_class.account_key_for("utilities")).to eq("expense_utilities")
      expect(described_class.account_key_for("other")).to eq("expense_other")
    end

    it "handles symbol keys" do
      expect(described_class.account_key_for(:utilities)).to eq("expense_utilities")
    end

    it "raises UnknownExpenseKindError for unsupported kinds" do
      expect {
        described_class.account_key_for("depreciation_expense")
      }.to raise_error(Expenses::AccountMap::UnknownExpenseKindError, /No accounting mapping defined/)
    end
  end
end
