require "test_helper"

class ExpensesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @expense = expenses(:one)
  end

  test "should get index" do
    get expenses_url
    assert_response :success
  end

  test "should get new" do
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)
    other_tenant = Tenant.create!(user: other_user, name: "Other Tenant")
    other_lease = Lease.create!(
      rental_property: other_property,
      commencement_date: Date.current,
      annual_rental_amount: 12000,
      lease_type: :term
    )
    LeaseTenant.create!(lease: other_lease, tenant: other_tenant)

    get new_expense_url

    assert_response :success
    assert_no_match other_property.address, response.body
    assert_no_match other_tenant.name, response.body
  end

  test "should create expense" do
    assert_difference("Expense.count") do
      post expenses_url, params: { expense: { amount: @expense.amount, category: @expense.category, description: @expense.description, expense_date: @expense.expense_date, rental_property_id: @expense.rental_property_id } }
    end

    assert_redirected_to expense_url(Expense.last)
  end

  test "should show expense" do
    get expense_url(@expense)
    assert_response :success
  end

  test "should get edit" do
    get edit_expense_url(@expense)
    assert_response :success
  end

  test "should update expense" do
    patch expense_url(@expense), params: { expense: { amount: @expense.amount, category: @expense.category, description: @expense.description, expense_date: @expense.expense_date, rental_property_id: @expense.rental_property_id } }
    assert_redirected_to expense_url(@expense)
  end

  test "should destroy" do
    assert_difference("Expense.count", -1) do
      delete expense_url(@expense)
    end

    assert_redirected_to expenses_url
  end

  test "should not create expense with other user's property" do
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)

    assert_no_difference("Expense.count") do
      post expenses_url, params: { expense: { amount: 100.0, category: "repairs", expense_date: Date.current, rental_property_id: other_property.id } }
      assert_response :not_found
    end
  end

  test "should not update expense to other user's property" do
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)

    patch expense_url(@expense), params: { expense: { rental_property_id: other_property.id } }
    assert_response :not_found
  end

  test "should not create expense with other user's reimburse lease" do
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)
    other_lease = Lease.create!(rental_property: other_property, commencement_date: Date.current - 1.day, annual_rental_amount: 12000, lease_type: :term)

    assert_no_difference("Expense.count") do
      post expenses_url, params: { expense: { amount: 100.0, category: "repairs", expense_date: Date.current, rental_property_id: @expense.rental_property_id, reimburse_lease_id: other_lease.id } }
      assert_response :not_found
    end
  end

  test "should fail validation and return errors when custom reimburse amount is invalid" do
    assert_no_difference("Expense.count") do
      post expenses_url, params: {
        expense: {
          amount: 100.0,
          category: "repairs",
          expense_date: Date.current,
          rental_property_id: @expense.rental_property_id,
          tenant_reimbursable: "1",
          reimburse_lease_id: leases(:one).id,
          reimburse_amount: -50.0
        }
      }, as: :json
    end

    assert_response :unprocessable_entity
    response_json = JSON.parse(response.body)
    assert_includes response_json.keys, "reimburse_amount"
  end
end
