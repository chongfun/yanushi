require "application_system_test_case"

class ExpensesTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @property = RentalProperty.create!(user: @user, address: "999 Expense Ave", property_type: "residential", square_footage: 1000)

    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "creating an expense with IRS category" do
    visit expenses_path

    click_on "New expense"

    select @property.address, from: "Rental property"
    # Testing that category enum contains repairs
    select "Repairs", from: "Category"
    fill_in "Expense date", with: Date.today.to_s
    fill_in "Amount", with: "450.00"
    fill_in "Description", with: "Fixed the leaky roof"

    click_on "Create Expense"

    assert_text "Expense was successfully created"
    assert_text "Repairs"
    assert_text "Fixed the leaky roof"
  end
end
