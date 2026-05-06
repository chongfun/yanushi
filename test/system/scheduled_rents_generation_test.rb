require "application_system_test_case"

class ScheduledRentsGenerationTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @property = RentalProperty.create!(user: @user, address: "100 Rent Gen Ave", property_type: "single_family_residence", square_footage: 1000)
    @lease = Lease.create!(
      rental_property: @property,
      lease_type: :term,
      commencement_date: Date.new(2025, 1, 1),
      termination_date: Date.new(2025, 12, 31),
      annual_rental_amount: 12000,
      late_period_days: 5
    )

    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  test "generating scheduled rents multiple times does not duplicate them" do
    # Initial rents from after_create callback
    assert_equal 12, @lease.scheduled_rents.count

    visit lease_path(@lease)

    # Click the Generate Rents button for 2025
    fill_in "year", with: "2025"
    click_on "Generate Rents"

    assert_text "Scheduled rents for 2025 have been generated"

    # Verify we still only have 12 rents (no duplicates)
    assert_equal 12, @lease.scheduled_rents.count
  end

  test "generating scheduled rents for a new year on a month-to-month lease" do
    month_lease = Lease.create!(
      rental_property: @property,
      lease_type: :month_to_month,
      commencement_date: Date.new(2025, 5, 1),
      annual_rental_amount: 12000,
      late_period_days: 5
    )

    # Initial rents generated for the first year (2025). From May to Dec = 8 rents.
    # We will just verify it creates new rents when we click the button for 2026.

    visit lease_path(month_lease)

    fill_in "year", with: "2026"
    click_on "Generate Rents"

    assert_text "Scheduled rents for 2026 have been generated"

    # Should have 12 new rents for 2026
    assert_equal 12, month_lease.scheduled_rents.where(due_date: Date.new(2026, 1, 1)..Date.new(2026, 12, 31)).count
  end
end
