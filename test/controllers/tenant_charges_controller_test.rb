require "test_helper"

class TenantChargesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @tenant_charge = tenant_charges(:one)
  end

  test "should show tenant_charge" do
    get tenant_charge_url(@tenant_charge)
    assert_response :success
  end

  test "should destroy tenant_charge" do
    assert_difference("TenantCharge.count", -1) do
      delete tenant_charge_url(@tenant_charge)
    end

    assert_redirected_to expenses_url
  end

  test "should not show another user's tenant_charge" do
    other_charge = tenant_charge_for(users(:two))

    get tenant_charge_url(other_charge)

    assert_response :not_found
  end

  test "should not destroy another user's tenant_charge" do
    other_charge = tenant_charge_for(users(:two))

    assert_no_difference("TenantCharge.count") do
      delete tenant_charge_url(other_charge)
    end

    assert_response :not_found
  end

  private
    def tenant_charge_for(user)
      property = RentalProperty.create!(user: user, address: "999 Other St", property_type: :other)
      lease = Lease.create!(
        rental_property: property,
        commencement_date: Date.current,
        annual_rental_amount: 12000,
        lease_type: :term
      )
      expense = Expense.create!(
        rental_property: property,
        amount: 100,
        category: :repairs,
        expense_date: Date.current
      )
      TenantCharge.create!(lease: lease, expense: expense, amount: 100, charge_date: Date.current)
    end
end
