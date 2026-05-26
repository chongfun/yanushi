require "test_helper"

class LeaseTest < ActiveSupport::TestCase
  setup do
    @property = RentalProperty.create!(
      user: users(:one),
      address: "456 Oak Ave",
      property_type: :single_family_residence,
      square_footage: 2000
    )
    @lease = Lease.create!(
      rental_property: @property,
      commencement_date: Date.parse("2026-01-01"),
      termination_date: Date.parse("2026-12-31"),
      annual_rental_amount: 14400.0,
      security_deposit: 1200.0,
      lease_type: :term,
      late_period_days: 3
    )
  end

  test "Scenario 1: Simple monthly rent" do
    rent = ScheduledRent.create!(lease: @lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))

    # Before payment: balance is -1200
    assert_equal -1200.00, @lease.balance_as_of(Date.parse("2026-01-01"))
    assert_not rent.covered?

    # Payment of 1200 made on Jan 5
    TenantPayment.create!(lease: @lease, amount: 1200.00, payment_date: Date.parse("2026-01-05"), payment_method: "check")

    # Balance as of Jan 5 is 0
    assert_equal 0.00, @lease.balance_as_of(Date.parse("2026-01-05"))
    assert rent.covered?
  end

  test "Scenario 2: Payment covers rent + utility charge" do
    rent = ScheduledRent.create!(lease: @lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))

    # Overpayment on Jan 3
    TenantPayment.create!(lease: @lease, amount: 1500.00, payment_date: Date.parse("2026-01-03"), payment_method: "zelle")

    # Expense recorded and reimbursable TenantCharge created on Jan 15
    expense = Expense.create!(rental_property: @property, category: :utilities, amount: 300.00, expense_date: Date.parse("2026-01-15"))
    charge = TenantCharge.create!(lease: @lease, expense: expense, amount: 300.00, charge_date: Date.parse("2026-01-15"))

    # Balance as of Jan 1 is -1200
    assert_equal -1200.00, @lease.balance_as_of(Date.parse("2026-01-01"))
    # Balance as of Jan 3 is +300
    assert_equal 300.00, @lease.balance_as_of(Date.parse("2026-01-03"))
    # Balance as of Jan 15 is 0
    assert_equal 0.00, @lease.balance_as_of(Date.parse("2026-01-15"))

    assert rent.covered?
  end

  test "Scenario 3: Overpayment carries forward" do
    rent_jan = ScheduledRent.create!(lease: @lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))
    rent_feb = ScheduledRent.create!(lease: @lease, amount: 1200.00, due_date: Date.parse("2026-02-01"))

    # Large payment of 2400 on Jan 3
    TenantPayment.create!(lease: @lease, amount: 2400.00, payment_date: Date.parse("2026-01-03"), payment_method: "zelle")

    assert rent_jan.covered?
    assert rent_feb.covered?
    assert_equal 0.00, @lease.balance_as_of(Date.parse("2026-02-01"))
  end

  test "Scenario 4: Partial payment leaves rent uncovered" do
    rent = ScheduledRent.create!(lease: @lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))

    # Partial payment of 600 on Jan 5
    TenantPayment.create!(lease: @lease, amount: 600.00, payment_date: Date.parse("2026-01-05"), payment_method: "zelle")

    assert_equal -600.00, @lease.balance_as_of(Date.parse("2026-01-05"))
    assert_not rent.covered?
  end

  test "Scenario 5: Late payment check" do
    rent = ScheduledRent.create!(lease: @lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))

    # Current date is mocked or advanced manually via travel_to or by date comparison
    # If today is Jan 10 (which is > Jan 1 + 3 days), then the rent is late
    # Let's verify our late? logic using custom date math
    # We want to travel to Jan 10
    travel_to Date.parse("2026-01-10") do
      assert rent.late?
    end

    # Make payment
    TenantPayment.create!(lease: @lease, amount: 1200.00, payment_date: Date.parse("2026-01-05"), payment_method: "zelle")

    travel_to Date.parse("2026-01-10") do
      assert_not rent.late?
    end
  end

  test "Scenario 6: In-place lease renewal with rate increase" do
    lease = Lease.create!(
      rental_property: @property,
      lease_type: :term,
      commencement_date: Date.parse("2026-01-01"),
      termination_date: Date.parse("2026-03-31"),
      annual_rental_amount: 12000 # $1000/mo
    )
    Leases::ScheduledRentSyncService.call(lease, previously_new_record: true)

    assert_equal 3, lease.scheduled_rents.count
    assert_equal [ 1000.0, 1000.0, 1000.0 ], lease.scheduled_rents.order(:due_date).map(&:amount)

    # Now renew in-place with rate increase ($1200/mo) for another 3 months
    lease.update!(
      termination_date: Date.parse("2026-06-30"),
      annual_rental_amount: 14400 # $1200/mo
    )
    Leases::ScheduledRentSyncService.call(lease)

    # Total rents should be 6
    assert_equal 6, lease.scheduled_rents.count
    # The first 3 should be $1000, the last 3 should be $1200
    expected_amounts = [ 1000.0, 1000.0, 1000.0, 1200.0, 1200.0, 1200.0 ]
    assert_equal expected_amounts, lease.scheduled_rents.order(:due_date).map(&:amount)

    # The balance should carry forward naturally
    # Create payments of $6600 (covers 3 * $1000 + 3 * $1200)
    TenantPayment.create!(lease: lease, amount: 6600.0, payment_date: Date.parse("2026-01-01"), payment_method: "zelle")
    assert_equal 0.0, lease.balance_as_of(Date.parse("2026-06-30"))
  end

  test "Scenario 7: In-place lease conversion from term to month-to-month" do
    lease = Lease.create!(
      rental_property: @property,
      lease_type: :term,
      commencement_date: Date.parse("2026-01-01"),
      termination_date: Date.parse("2026-03-31"),
      annual_rental_amount: 12000 # $1000/mo
    )
    Leases::ScheduledRentSyncService.call(lease, previously_new_record: true)

    assert_equal 3, lease.scheduled_rents.count

    # Convert to Month-to-Month
    travel_to Date.parse("2026-04-01") do
      lease.update!(
        lease_type: :month_to_month,
        termination_date: nil
      )
      Leases::ScheduledRentSyncService.call(lease)

      # Should generate rents rolling forward (12 months from today, or 11 months from commencement, max)
      # Date.current is 2026-04-01, +12 months = 2027-04-01 (approx 16 total months generated)
      assert lease.scheduled_rents.count >= 15
    end
  end
end
