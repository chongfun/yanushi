require 'rails_helper'

RSpec.describe ScheduledRent, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  describe 'associations' do
    it { should belong_to(:lease) }
  end

  describe 'validations' do
    it { should validate_presence_of(:amount) }
    it { should validate_numericality_of(:amount).is_greater_than(0) }
    it { should validate_presence_of(:due_date) }
  end

  describe 'instance methods' do
    let(:user) { create(:user) }
    let(:property) { create(:rental_property, user: user) }
    let(:lease) { create(:lease, rental_property: property, late_period_days: 5) }
    let(:rent) { create(:scheduled_rent, lease: lease, amount: 1000.0, due_date: Date.parse("2026-05-01")) }

    describe '#covered?' do
      it 'returns false when not paid' do
        expect(rent.covered?).to be_falsey
      end

      it 'returns true when fully paid' do
        create(:tenant_payment, lease: lease, amount: 1000.0, payment_date: Date.parse("2026-05-01"))
        expect(rent.covered?).to be_truthy
      end
    end

    describe '#late?' do
      it 'returns false if covered' do
        create(:tenant_payment, lease: lease, amount: 1000.0, payment_date: Date.parse("2026-05-01"))
        travel_to Date.parse("2026-05-10") do
          expect(rent.late?).to be_falsey
        end
      end

      it 'returns false if not covered but before late period grace days' do
        travel_to Date.parse("2026-05-03") do
          expect(rent.late?).to be_falsey
        end
      end

      it 'returns true if not covered and after late period grace days' do
        travel_to Date.parse("2026-05-07") do
          expect(rent.late?).to be_truthy
        end
      end
    end

    describe '#display_name' do
      it 'returns formatted display name' do
        expect(rent.display_name).to eq("#{property.address} - 2026-05-01")
      end
    end
  end
end
