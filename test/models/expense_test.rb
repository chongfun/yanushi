require "test_helper"

class ExpenseTest < ActiveSupport::TestCase
  setup do
    @property = rental_properties(:one)
    @lease = leases(:one)
  end

  test "creating a reimbursable expense creates a matching tenant charge" do
    expense = Expense.new(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill",
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id
    )

    assert_difference -> { TenantCharge.count }, 1 do
      save_with_tenant_charge!(expense)
    end

    charge = expense.tenant_charge
    assert_equal 150.00, charge.amount
    assert_equal @lease.id, charge.lease_id
  end

  test "creating a reimbursable expense with a custom amount" do
    expense = Expense.new(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill",
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id,
      reimburse_amount: 75.00
    )

    save_with_tenant_charge!(expense)
    assert_equal 75.00, expense.tenant_charge.amount
  end

  test "updating expense amount automatically updates charge amount if it was matching" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill",
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id
    )
    Expenses::TenantChargeService.call(expense)

    # Simulates submitting the edit form where reinforce_amount is pre-populated with the old value 150.00
    # and they only change the expense amount to 200.00
    expense.assign_attributes(amount: 200.00, reimburse_amount: "150.00")
    save_with_tenant_charge!(expense)

    assert_equal 200.00, expense.tenant_charge.amount
  end

  test "updating expense amount does not update charge amount if charge was previously custom" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill",
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id,
      reimburse_amount: 50.00 # custom
    )
    Expenses::TenantChargeService.call(expense)

    # Form pre-populates custom amount 50.00, user updates expense to 200.00
    expense.assign_attributes(amount: 200.00, reimburse_amount: "50.00")
    save_with_tenant_charge!(expense)

    assert_equal 50.00, expense.tenant_charge.amount
  end

  test "clearing reimbursement amount in the form syncs it back to expense amount" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill",
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id,
      reimburse_amount: 50.00 # custom
    )
    Expenses::TenantChargeService.call(expense)

    # Form submits empty string for reimburse_amount (clear custom)
    expense.assign_attributes(amount: 150.00, reimburse_amount: "")
    save_with_tenant_charge!(expense)

    assert_equal 150.00, expense.tenant_charge.amount
  end

  test "programmatic update of expense amount syncs the charge amount if it was matching" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill",
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id
    )
    Expenses::TenantChargeService.call(expense)

    # Unrelated programmatic update or direct ActiveRecord update without setting virtual attribute
    expense.update!(amount: 180.00)
    Expenses::TenantChargeService.call(expense)

    assert_equal 180.00, expense.tenant_charge.reload.amount
  end

  test "programmatic update of expense amount does not sync custom charge amount" do
    expense = Expense.create!(
      rental_property: @property,
      amount: 150.00,
      category: "utilities",
      expense_date: Date.current,
      description: "Water bill",
      tenant_reimbursable: true,
      reimburse_lease_id: @lease.id,
      reimburse_amount: 50.00 # custom
    )
    Expenses::TenantChargeService.call(expense)

    expense.update!(amount: 180.00)
    Expenses::TenantChargeService.call(expense)

    assert_equal 50.00, expense.tenant_charge.reload.amount
  end

  private
    def save_with_tenant_charge!(expense)
      expense.save!
      Expenses::TenantChargeService.call(expense)
    end
end
