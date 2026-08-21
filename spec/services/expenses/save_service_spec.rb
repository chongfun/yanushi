require "rails_helper"

RSpec.describe Expenses::SaveService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "saves the expense and syncs tenant charges in one workflow" do
    expense = build(:expense, property: property, tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id)

    expect {
      result = described_class.call(expense: expense)
      expect(result).to be_success
    }.to change(Expense, :count).by(1).and change(TenantCharge, :count).by(1)
  end

  it "returns validation errors without persisting" do
    expense = build(:expense, property: property, amount: -1)

    result = described_class.call(expense: expense)

    expect(result).to be_failure
    expect(expense).not_to be_persisted
  end
end
