require "test_helper"

class Leases::ScheduledRentSyncServiceTest < ActiveSupport::TestCase
  setup do
    @property = rental_properties(:one)
  end

  test "generates scheduled rents for a new term lease" do
    lease = Lease.create!(
      rental_property: @property,
      commencement_date: Date.new(2026, 1, 1),
      termination_date: Date.new(2026, 12, 31),
      annual_rental_amount: 12000,
      lease_type: :term,
      late_period_days: 5
    )
    # Clear callback generated rents to test service in isolation
    lease.scheduled_rents.destroy_all

    assert_difference -> { lease.scheduled_rents.count }, 12 do
      Leases::ScheduledRentSyncService.call(lease, previously_new_record: true)
    end

    rents = lease.scheduled_rents.order(:due_date)
    assert_equal Date.new(2026, 1, 1), rents.first.due_date
    assert_equal Date.new(2026, 12, 1), rents.last.due_date
    rents.each { |r| assert_equal 1000.0, r.amount.to_f }
  end

  test "generates rolling forward rents for a new month-to-month lease" do
    lease = Lease.create!(
      rental_property: @property,
      commencement_date: Date.new(2026, 1, 1),
      annual_rental_amount: 12000,
      lease_type: :month_to_month,
      late_period_days: 5
    )
    lease.scheduled_rents.destroy_all

    assert_difference -> { lease.scheduled_rents.count }, 12 do
      Leases::ScheduledRentSyncService.call(lease, previously_new_record: true)
    end

    rents = lease.scheduled_rents.order(:due_date)
    assert_equal Date.new(2026, 1, 1), rents.first.due_date
    assert_equal Date.new(2026, 12, 1), rents.last.due_date
  end

  test "generates rolling forward rents from Date.current for existing month-to-month lease" do
    lease = Lease.create!(
      rental_property: @property,
      commencement_date: Date.new(2025, 1, 1),
      annual_rental_amount: 12000,
      lease_type: :month_to_month,
      late_period_days: 5
    )
    lease.scheduled_rents.destroy_all

    # Let's freeze/travel time to 2026-05-15 to check rolling forward from current date
    travel_to Date.new(2026, 5, 15) do
      Leases::ScheduledRentSyncService.call(lease, previously_new_record: false)

      # Rents should be generated from Jan 2025 (commencement) up to 12 months after Date.current (May 2027)
      # Date.current + 12.months = 2027-05-15, meaning end_date is 2027-05-15, which translates to May 2027
      # Months between Jan 2025 and May 2027 (inclusive) = 29 months.
      assert_equal 29, lease.scheduled_rents.count

      rents = lease.scheduled_rents.order(:due_date)
      assert_equal Date.new(2025, 1, 1), rents.first.due_date
      assert_equal Date.new(2027, 5, 1), rents.last.due_date
    end
  end
end
