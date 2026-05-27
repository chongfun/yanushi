require 'rails_helper'

RSpec.describe Expenses::TenantChargeService do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }

  it 'creates a matching tenant charge when tenant_reimbursable is true' do
    expense = create(:expense,
      rental_property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill"
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_lease_id: lease.id)

    expect {
      Expenses::TenantChargeService.call(expense)
    }.to change(TenantCharge, :count).by(1)

    charge = expense.tenant_charge
    expect(charge.amount).to eq(150.00)
    expect(charge.lease_id).to eq(lease.id)
    expect(charge.description).to eq("Reimbursement for utilities: Water bill")
  end

  it 'destroys tenant charge when tenant_reimbursable is false' do
    expense = create(:expense,
      rental_property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_lease_id: lease.id)
    Expenses::TenantChargeService.call(expense)
    expect(expense.tenant_charge).to be_present

    expense.tenant_reimbursable = false
    expect {
      Expenses::TenantChargeService.call(expense)
    }.to change(TenantCharge, :count).by(-1)
    expect(expense.reload.tenant_charge).to be_nil
  end

  it 'uses custom amount when reimburse_amount is set' do
    expense = create(:expense,
      rental_property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_lease_id: lease.id, reimburse_amount: 75.00)
    Expenses::TenantChargeService.call(expense)

    expect(expense.tenant_charge.amount).to eq(75.00)
  end

  it 'falls back to expense amount when raw_reimburse_amount is empty string' do
    expense = create(:expense,
      rental_property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_lease_id: lease.id, reimburse_amount: "")
    Expenses::TenantChargeService.call(expense)

    expect(expense.tenant_charge.amount).to eq(150.00)
  end

  it 'updates matching charge amount when expense amount is changed programmatically' do
    expense = create(:expense,
      rental_property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_lease_id: lease.id)
    Expenses::TenantChargeService.call(expense)

    expense.update!(amount: 200.00)
    Expenses::TenantChargeService.call(expense)

    expect(expense.tenant_charge.reload.amount).to eq(200.00)
  end

  it 'does not update custom charge amount when expense amount is changed programmatically' do
    expense = create(:expense,
      rental_property: property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current
    )
    expense.assign_attributes(tenant_reimbursable: true, reimburse_lease_id: lease.id, reimburse_amount: 75.00)
    Expenses::TenantChargeService.call(expense)

    expense.update!(amount: 200.00)
    Expenses::TenantChargeService.call(expense)

    expect(expense.tenant_charge.reload.amount).to eq(75.00)
  end

  it 'falls back to the first lease of the rental property when reimburse_lease_id is blank' do
    lease
    expense = create(:expense, rental_property: property, amount: 150.00, category: "utilities", expense_date: Date.current)
    expense.assign_attributes(tenant_reimbursable: true, reimburse_lease_id: nil)
    # property has `lease` (which is its first lease)
    expect {
      Expenses::TenantChargeService.call(expense)
    }.to change(TenantCharge, :count).by(1)
    expect(expense.tenant_charge.lease_id).to eq(lease.id)
  end

  it 'returns nil and does not create a charge if there are no leases on the property' do
    property_without_leases = create(:rental_property, user: user)
    expense = create(:expense, rental_property: property_without_leases, amount: 150.00, category: "utilities", expense_date: Date.current)
    expense.assign_attributes(tenant_reimbursable: true, reimburse_lease_id: nil)
    expect {
      Expenses::TenantChargeService.call(expense)
    }.not_to change(TenantCharge, :count)
  end

  it 'falls back to expense amount when raw_reimburse_amount is an invalid string' do
    expense = create(:expense, rental_property: property, amount: 150.00, category: "utilities", expense_date: Date.current)
    expense.assign_attributes(tenant_reimbursable: true, reimburse_lease_id: lease.id, reimburse_amount: "abc")
    Expenses::TenantChargeService.call(expense)
    expect(expense.tenant_charge.amount).to eq(150.00)
  end
end
