require 'rails_helper'

RSpec.describe "ScheduledRentsGeneration", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:rental_property, user: user, address: "100 Rent Gen Ave") }
  let!(:lease) do
    create(:lease,
      rental_property: property,
      lease_type: :term,
      commencement_date: Date.new(2025, 1, 1),
      termination_date: Date.new(2025, 12, 31),
      annual_rental_amount: 12000,
      late_period_days: 5
    )
  end

  before do
    Leases::ScheduledRentSyncService.call(lease, previously_new_record: true)
    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "generating scheduled rents multiple times does not duplicate them" do
    expect(lease.scheduled_rents.count).to eq(12)

    visit lease_path(lease)

    fill_in "year", with: "2025"
    click_on "Generate Rents"

    expect(page).to have_text("Scheduled rents for 2025 have been generated")
    expect(lease.scheduled_rents.count).to eq(12)
  end

  it "generates scheduled rents for a new year on a month-to-month lease" do
    month_lease = create(:lease,
      rental_property: property,
      lease_type: :month_to_month,
      commencement_date: Date.new(2025, 5, 1),
      annual_rental_amount: 12000,
      late_period_days: 5
    )

    visit lease_path(month_lease)

    fill_in "year", with: "2026"
    click_on "Generate Rents"

    expect(page).to have_text("Scheduled rents for 2026 have been generated")

    expect(month_lease.scheduled_rents.where(due_date: Date.new(2026, 1, 1)..Date.new(2026, 12, 31)).count).to eq(12)
  end
end
