require 'rails_helper'

RSpec.describe Leases::ScheduledRentSyncService do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }

  it 'generates scheduled rents for a new term lease' do
    lease = create(:lease,
      rental_property: property,
      commencement_date: Date.new(2026, 1, 1),
      termination_date: Date.new(2026, 12, 31),
      annual_rental_amount: 12000,
      lease_type: :term,
      late_period_days: 5
    )
    # Clear callback generated rents to test service in isolation
    lease.scheduled_rents.destroy_all

    expect {
      Leases::ScheduledRentSyncService.call(lease, previously_new_record: true)
    }.to change { lease.scheduled_rents.count }.by(12)

    rents = lease.scheduled_rents.order(:due_date)
    expect(rents.first.due_date).to eq(Date.new(2026, 1, 1))
    expect(rents.last.due_date).to eq(Date.new(2026, 12, 1))
    rents.each { |r| expect(r.amount.to_f).to eq(1000.0) }
  end

  it 'generates rolling forward rents for a new month-to-month lease' do
    lease = create(:lease,
      rental_property: property,
      commencement_date: Date.new(2026, 1, 1),
      annual_rental_amount: 12000,
      lease_type: :month_to_month,
      late_period_days: 5
    )
    lease.scheduled_rents.destroy_all

    expect {
      Leases::ScheduledRentSyncService.call(lease, previously_new_record: true)
    }.to change { lease.scheduled_rents.count }.by(12)

    rents = lease.scheduled_rents.order(:due_date)
    expect(rents.first.due_date).to eq(Date.new(2026, 1, 1))
    expect(rents.last.due_date).to eq(Date.new(2026, 12, 1))
  end

  it 'generates rolling forward rents from Date.current for existing month-to-month lease' do
    lease = create(:lease,
      rental_property: property,
      commencement_date: Date.new(2025, 1, 1),
      annual_rental_amount: 12000,
      lease_type: :month_to_month,
      late_period_days: 5
    )
    lease.scheduled_rents.destroy_all

    travel_to Date.new(2026, 5, 15) do
      Leases::ScheduledRentSyncService.call(lease, previously_new_record: false)

      # Rents should be generated from Jan 2025 (commencement) up to 12 months after Date.current (May 2027)
      # Months between Jan 2025 and May 2027 (inclusive) = 29 months.
      expect(lease.scheduled_rents.count).to eq(29)

      rents = lease.scheduled_rents.order(:due_date)
      expect(rents.first.due_date).to eq(Date.new(2025, 1, 1))
      expect(rents.last.due_date).to eq(Date.new(2027, 5, 1))
    end
  end
end
