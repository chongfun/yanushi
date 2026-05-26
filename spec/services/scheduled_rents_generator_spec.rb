require 'rails_helper'

RSpec.describe ScheduledRentsGenerator do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) do
    create(:lease,
      rental_property: property,
      commencement_date: Date.new(2025, 1, 1),
      annual_rental_amount: 12000,
      lease_type: :term,
      termination_date: Date.new(2025, 12, 31)
    )
  end

  it "generates 12 rents for a full year term lease" do
    expect {
      described_class.new(lease, 2025).call
    }.to change { lease.scheduled_rents.count }.by(12)

    first_rent = lease.scheduled_rents.order(:due_date).first
    expect(first_rent.due_date).to eq(Date.new(2025, 1, 1))
    expect(first_rent.amount.to_f).to eq(1000.0)
  end

  it "does not generate duplicate rents for the same month" do
    described_class.new(lease, 2025).call

    expect {
      described_class.new(lease, 2025).call
    }.not_to change { lease.scheduled_rents.count }
  end

  it "skips months before lease commencement" do
    lease.update!(commencement_date: Date.new(2025, 6, 1))

    expect {
      described_class.new(lease, 2025).call
    }.to change { lease.scheduled_rents.count }.by(7)

    expect(lease.scheduled_rents.order(:due_date).first.due_date).to eq(Date.new(2025, 6, 1))
  end

  it "skips months after lease termination" do
    lease.update!(termination_date: Date.new(2025, 6, 30))

    expect {
      described_class.new(lease, 2025).call
    }.to change { lease.scheduled_rents.count }.by(6)

    expect(lease.scheduled_rents.order(:due_date).last.due_date).to eq(Date.new(2025, 6, 1))
  end

  it "respects the end_date parameter" do
    expect {
      described_class.new(lease, 2025, end_date: Date.new(2025, 3, 31)).call
    }.to change { lease.scheduled_rents.count }.by(3)
  end

  it "aligns due dates to the first of the month on or after commencement" do
    lease.update!(commencement_date: Date.new(2025, 1, 15))
    described_class.new(lease, 2025).call

    rents = lease.scheduled_rents.order(:due_date)
    expect(rents.first.due_date).to eq(Date.new(2025, 2, 1))
    expect(rents.map { |rent| rent.due_date.day }.uniq).to eq([ 1 ])

    lease.update!(commencement_date: Date.new(2025, 1, 1))
    lease.scheduled_rents.destroy_all
    described_class.new(lease, 2025).call

    rents = lease.scheduled_rents.order(:due_date)
    expect(rents.first.due_date).to eq(Date.new(2025, 1, 1))
    expect(rents.map { |rent| rent.due_date.day }.uniq).to eq([ 1 ])
  end

  it "truncates monthly rent to cents for term series" do
    lease.update!(
      commencement_date: Date.new(2025, 1, 1),
      termination_date: Date.new(2025, 12, 31),
      annual_rental_amount: 10000.00
    )

    described_class.new(lease, 2025).call

    rents = lease.scheduled_rents.order(:due_date)
    expect(rents.size).to eq(12)
    expect(rents.map { |rent| rent.amount.to_f }.uniq).to eq([ 833.33 ])
  end
end
