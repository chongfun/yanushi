require "rails_helper"

RSpec.describe Expenses::SaveService do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }

  it "saves the expense and syncs tenant charges in one workflow" do
    expense = build(:expense, rental_property: property, tenant_reimbursable: true, reimburse_lease_id: lease.id)

    expect {
      result = described_class.call(expense: expense)
      expect(result).to be_success
    }.to change(Expense, :count).by(1).and change(TenantCharge, :count).by(1)
  end

  it "returns validation errors without persisting" do
    expense = build(:expense, rental_property: property, amount: -1)

    result = described_class.call(expense: expense)

    expect(result).to be_failure
    expect(expense).not_to be_persisted
  end
end
