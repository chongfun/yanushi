require "rails_helper"

RSpec.describe Leases::SaveService do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }

  it "saves and syncs scheduled rents for a new lease" do
    lease = build(:lease,
      rental_property: property,
      lease_type: :term,
      commencement_date: Date.new(2026, 1, 1),
      termination_date: Date.new(2026, 3, 31),
      annual_rental_amount: 12000
    )

    expect {
      result = described_class.call(lease: lease, sync_scheduled_rents: true, previously_new_record: true)
      expect(result).to be_success
    }.to change(Lease, :count).by(1).and change(ScheduledRent, :count).by(3)
  end

  it "does not sync scheduled rents when tracked rent fields are unchanged" do
    lease = create(:lease, rental_property: property)
    lease.assign_attributes(security_deposit: 1000)

    expect(Leases::ScheduledRentSyncService).not_to receive(:call)

    result = described_class.call(lease: lease)

    expect(result).to be_success
    expect(lease.reload.security_deposit).to eq(1000)
  end
end
