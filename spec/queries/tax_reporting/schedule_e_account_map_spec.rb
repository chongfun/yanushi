require "rails_helper"

RSpec.describe TaxReporting::ScheduleEAccountMap do
  it "maps every active system expense account to a supported Schedule E category" do
    system_expense_keys = Accounting::ChartOfAccounts::SYSTEM_ACCOUNTS
      .select { |acct| acct[:account_type] == "expense" }
      .map { |acct| acct[:key] }

    expect(described_class.supported_keys).to contain_exactly(*system_expense_keys)
  end

  it "returns the correct category for known account keys" do
    expect(described_class.category_for("expense_advertising")).to eq(:advertising)
    expect(described_class.category_for("expense_utilities")).to eq(:utilities)
    expect(described_class.category_for("expense_repairs")).to eq(:repairs)
    expect(described_class.category_for("expense_other")).to eq(:other)
    expect(described_class.category_for("unknown_key")).to be_nil
  end
end
