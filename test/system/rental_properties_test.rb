require "application_system_test_case"

class RentalPropertiesTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "creating a rental property" do
    visit rental_properties_path
    click_on "New rental property"

    fill_in "Address", with: "123 Main St"
    select "Residential", from: "Property type"
    fill_in "Square footage", with: 1500

    click_on "Create Rental property"

    assert_text "Rental property was successfully created"
    assert_text "123 Main St"
  end
  test "filtering the financial ledger by year" do
    rental_property = rental_properties(:one)
    past_year = Date.current.year - 1

    # Create an expense in the past year
    Expense.create!(
      rental_property: rental_property,
      category: "repairs",
      amount: 50.00,
      expense_date: Date.new(past_year, 5, 15),
      description: "Past year plumbing"
    )

    visit rental_property_path(rental_property)

    # We should see the current year's scheduled rent from the fixture, but not the past year's expense
    assert_text "Scheduled Rent"
    assert_no_text "Past year plumbing"

    # Since RackTest does not execute JavaScript, the auto-submit on the select
    # dropdown won't fire. We manually visit the filtered URL.
    visit rental_property_path(rental_property, year: past_year)

    # We should now see the past year's expense, and NOT the current year's scheduled rent
    assert_text "Past year plumbing"
    assert_no_text "Scheduled Rent"
  end
end
