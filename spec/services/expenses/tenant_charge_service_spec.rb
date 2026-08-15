require "rails_helper"

RSpec.describe Expenses::TenantChargeService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "creates a matching tenant charge when tenant_reimbursable is true" do
    expense = create(:expense,
      property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill"
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id)

    expect {
      described_class.call(expense)
    }.to change(TenantCharge, :count).by(1)

    charge = expense.tenant_charge
    expect(charge.amount).to eq(150.00)
    expect(charge.tenancy_id).to eq(tenancy.id)
    expect(charge.description).to eq("Reimbursement for utilities: Water bill")
  end

  it "destroys tenant charge when tenant_reimbursable is false" do
    expense = create(:expense,
      property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id)
    described_class.call(expense)
    expect(expense.tenant_charge).to be_present

    expense.tenant_reimbursable = false
    expect {
      described_class.call(expense)
    }.to change(TenantCharge, :count).by(-1)
    expect(expense.reload.tenant_charge).to be_nil
  end

  it "uses custom amount when reimburse_amount is set" do
    expense = create(:expense,
      property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id, reimburse_amount: 75.00)
    described_class.call(expense)

    expect(expense.tenant_charge.amount).to eq(75.00)
  end

  it "falls back to expense amount when raw_reimburse_amount is empty string" do
    expense = create(:expense,
      property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id, reimburse_amount: "")
    described_class.call(expense)

    expect(expense.tenant_charge.amount).to eq(150.00)
  end

  it "updates matching charge amount when expense amount is changed programmatically" do
    expense = create(:expense,
      property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id)
    described_class.call(expense)

    expense.update!(amount: 200.00)
    described_class.call(expense)

    expect(expense.tenant_charge.reload.amount).to eq(200.00)
  end

  it "does not update custom charge amount when expense amount is changed programmatically" do
    expense = create(:expense,
      property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id, reimburse_amount: 75.00)
    described_class.call(expense)

    expense.update!(amount: 200.00)
    described_class.call(expense)

    expect(expense.tenant_charge.reload.amount).to eq(75.00)
  end

  it "falls back to the first tenancy of the property when reimburse_tenancy_id is blank" do
    tenancy
    expense = create(:expense, property: property, amount: 150.00, category: "utilities", expense_date: Date.current)
    expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: nil)

    expect {
      described_class.call(expense)
    }.to change(TenantCharge, :count).by(1)
    expect(expense.tenant_charge.tenancy_id).to eq(tenancy.id)
  end

  it "returns nil and does not create a charge if there are no tenancies on the property" do
    property_without_tenancies = create(:property, user: user)
    expense = create(:expense, property: property_without_tenancies, amount: 150.00, category: "utilities", expense_date: Date.current)
    expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: nil)
    expect {
      described_class.call(expense)
    }.not_to change(TenantCharge, :count)
  end

  it "falls back to expense amount when raw_reimburse_amount is an invalid string" do
    expense = create(:expense, property: property, amount: 150.00, category: "utilities", expense_date: Date.current)
    expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id, reimburse_amount: "abc")
    described_class.call(expense)
    expect(expense.tenant_charge.amount).to eq(150.00)
  end
end
