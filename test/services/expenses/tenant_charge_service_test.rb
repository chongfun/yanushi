require "test_helper"

class Expenses::TenantChargeServiceTest < ActiveSupport::TestCase
  setup do
    @property = rental_properties(:one)
    @lease = leases(:one)
  end

  test "creates a matching tenant charge when tenant_reimbursable is true" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill",
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id
    )

    assert_difference -> { TenantCharge.count }, 1 do
      Expenses::TenantChargeService.call(expense)
    end

    charge = expense.tenant_charge
    assert_equal 150.00, charge.amount
    assert_equal @lease.id, charge.lease_id
    assert_equal "Reimbursement for utilities: Water bill", charge.description
  end

  test "destroys tenant charge when tenant_reimbursable is false" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id
    )
    Expenses::TenantChargeService.call(expense)
    assert expense.tenant_charge.present?

    expense.tenant_reimbursable = false
    assert_difference -> { TenantCharge.count }, -1 do
      Expenses::TenantChargeService.call(expense)
    end
    assert_nil expense.reload.tenant_charge
  end

  test "uses custom amount when reimburse_amount is set" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id,
      reimburse_amount: 75.00
    )
    Expenses::TenantChargeService.call(expense)

    assert_equal 75.00, expense.tenant_charge.amount
  end

  test "falls back to expense amount when raw_reimburse_amount is empty string" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id,
      reimburse_amount: ""
    )
    Expenses::TenantChargeService.call(expense)

    assert_equal 150.00, expense.tenant_charge.amount
  end

  test "updates matching charge amount when expense amount is changed programmatically" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id
    )
    Expenses::TenantChargeService.call(expense)

    # Programmatic update of amount without setting reimburse_amount
    expense.update!(amount: 200.00)
    Expenses::TenantChargeService.call(expense)

    assert_equal 200.00, expense.tenant_charge.reload.amount
  end

  test "does not update custom charge amount when expense amount is changed programmatically" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id,
      reimburse_amount: 75.00
    )
    Expenses::TenantChargeService.call(expense)

    # Programmatic update of amount without setting reimburse_amount
    expense.update!(amount: 200.00)
    Expenses::TenantChargeService.call(expense)

    assert_equal 75.00, expense.tenant_charge.reload.amount
  end
end
