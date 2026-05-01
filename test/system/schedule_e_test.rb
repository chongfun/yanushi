require "application_system_test_case"

class ScheduleETest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @property = RentalProperty.create!(
      address: "Test Isolation St",
      property_type: :residential,
      square_footage: 2000,
      user: @user
    )

    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "verifying schedule e summary accuracy with all expense categories" do
    year = Date.current.year

    # Create income: Rent Payment
    lease = @property.leases.create!(
      commencement_date: Date.new(year, 1, 1),
      termination_date: Date.new(year, 12, 31),
      annual_rental_amount: 12000,
      lease_type: :term
    )

    # Scheduled rents are generated automatically by after_create
    scheduled_rent = lease.scheduled_rents.first
    scheduled_rent.rent_payments.create!(
      amount: 5000.00,
      payment_date: Date.new(year, 1, 5),
      payment_method: "Zelle"
    )

    # Create income: Utility Payment
    lease.utility_payments.create!(
      amount: 150.00,
      payment_date: Date.new(year, 2, 10),
      payment_method: "Check"
    )

    # Every category defined in the Expense model
    categories = [
      "advertising", "auto_and_travel", "cleaning_and_maintenance", "commissions",
      "insurance", "legal_and_other_professional_fees", "management_fees",
      "mortgage_interest", "other_interest", "repairs", "supplies", "taxes",
      "utilities", "depreciation_expense", "other"
    ]

    total_expenses = 0
    categories.each_with_index do |category, index|
      amount = 100.00 + (index * 10)
      total_expenses += amount
      @property.expenses.create!(
        category: category,
        amount: amount,
        expense_date: Date.new(year, 3, 1),
        description: "Test #{category}"
      )
    end

    # Visit the property page and open Schedule E summary
    visit rental_property_path(@property, year: year)
    click_on "📋 Schedule E"

    # Verify Income
    assert_text "Rents Received"
    assert_text "$5,000.00"
    assert_text "Utility Reimbursements"
    assert_text "$150.00"
    assert_text "Total Income"
    assert_text "$5,150.00"

    # Verify every expense is present
    categories.each_with_index do |category, index|
      amount = 100.00 + (index * 10)
      formatted_amount = ActionController::Base.helpers.number_to_currency(amount)
      assert_text formatted_amount
    end

    # Verify total expenses
    formatted_total_expenses = ActionController::Base.helpers.number_to_currency(total_expenses)
    assert_text "Total Expenses"
    assert_text formatted_total_expenses

    # Verify Net Income
    net_income = 5150.00 - total_expenses
    formatted_net = ActionController::Base.helpers.number_to_currency(net_income.abs)

    if net_income < 0
      assert_text "Net Loss"
    else
      assert_text "Net Income"
    end
    assert_text formatted_net
  end
end
