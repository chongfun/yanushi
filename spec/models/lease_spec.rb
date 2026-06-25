require 'rails_helper'

RSpec.describe Lease, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  describe 'associations' do
    it { should belong_to(:rental_property) }
    it { should have_many(:lease_tenants).dependent(:destroy) }
    it { should have_many(:tenants).through(:lease_tenants) }
    it { should have_many(:scheduled_rents).dependent(:destroy) }
    it { should have_many(:tenant_payments).dependent(:destroy) }
    it { should have_many(:tenant_charges).dependent(:destroy) }
  end

  describe 'enums' do
    it { should define_enum_for(:lease_type).with_values(month_to_month: 0, term: 1) }
  end

  describe 'validations' do
    it { should validate_presence_of(:commencement_date) }
    it { should validate_presence_of(:annual_rental_amount) }
    it { should validate_numericality_of(:annual_rental_amount).is_greater_than(0) }
    it { should validate_presence_of(:lease_type) }
  end

  describe 'scenarios and calculations' do
    let(:user) { create(:user) }
    let(:property) { create(:rental_property, user: user) }
    let(:lease) do
      create(:lease,
        rental_property: property,
        commencement_date: Date.parse("2026-01-01"),
        termination_date: Date.parse("2026-12-31"),
        annual_rental_amount: 14400.0,
        security_deposit: 1200.0,
        lease_type: :term,
        late_period_days: 3
      )
    end

    describe 'Scenario 1 & 4: Simple monthly rent & partial payment' do
      it 'handles rent coverage correctly for simple payment' do
        rent = create(:scheduled_rent, lease: lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))

        # Before payment: balance is -1200
        expect(lease.balance_as_of(Date.parse("2026-01-01"))).to eq(-1200.00)
        expect(rent.covered?).to be_falsey

        # Payment of 1200 made on Jan 5
        create(:tenant_payment, lease: lease, amount: 1200.00, payment_date: Date.parse("2026-01-05"), payment_method: "check")

        # Balance as of Jan 5 is 0
        expect(lease.balance_as_of(Date.parse("2026-01-05"))).to eq(0.00)
        expect(rent.covered?).to be_truthy
      end

      it 'leaves rent uncovered on partial payment' do
        rent = create(:scheduled_rent, lease: lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))

        # Partial payment of 600 on Jan 5
        create(:tenant_payment, lease: lease, amount: 600.00, payment_date: Date.parse("2026-01-05"), payment_method: "zelle")

        expect(lease.balance_as_of(Date.parse("2026-01-05"))).to eq(-600.00)
        expect(rent.covered?).to be_falsey
      end
    end

    describe 'Scenario 2: Payment covers rent + utility charge' do
      it 'calculates balance correctly with tenant charges' do
        rent = create(:scheduled_rent, lease: lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))

        # Overpayment on Jan 3
        create(:tenant_payment, lease: lease, amount: 1500.00, payment_date: Date.parse("2026-01-03"), payment_method: "zelle")

        # Expense recorded and reimbursable TenantCharge created on Jan 15
        expense = create(:expense, rental_property: property, category: :utilities, amount: 300.00, expense_date: Date.parse("2026-01-15"))
        charge = create(:tenant_charge, lease: lease, expense: expense, amount: 300.00, charge_date: Date.parse("2026-01-15"))

        # Balance as of Jan 1 is -1200
        expect(lease.balance_as_of(Date.parse("2026-01-01"))).to eq(-1200.00)
        # Balance as of Jan 3 is +300
        expect(lease.balance_as_of(Date.parse("2026-01-03"))).to eq(300.00)
        # Balance as of Jan 15 is 0
        expect(lease.balance_as_of(Date.parse("2026-01-15"))).to eq(0.00)

        expect(rent.covered?).to be_truthy
      end
    end

    describe 'Scenario 3: Overpayment carries forward' do
      it 'carries forward overpayment' do
        rent_jan = create(:scheduled_rent, lease: lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))
        rent_feb = create(:scheduled_rent, lease: lease, amount: 1200.00, due_date: Date.parse("2026-02-01"))

        # Large payment of 2400 on Jan 3
        create(:tenant_payment, lease: lease, amount: 2400.00, payment_date: Date.parse("2026-01-03"), payment_method: "zelle")

        expect(rent_jan.covered?).to be_truthy
        expect(rent_feb.covered?).to be_truthy
        expect(lease.balance_as_of(Date.parse("2026-02-01"))).to eq(0.00)
      end
    end

    describe 'Scenario 5: Late payment check' do
      it 'is late after due date + late period, not late before or after payment' do
        rent = create(:scheduled_rent, lease: lease, amount: 1200.00, due_date: Date.parse("2026-01-01"))

        travel_to Date.parse("2026-01-10") do
          expect(rent.late?).to be_truthy
        end

        # Make payment
        create(:tenant_payment, lease: lease, amount: 1200.00, payment_date: Date.parse("2026-01-05"), payment_method: "zelle")

        travel_to Date.parse("2026-01-10") do
          expect(rent.late?).to be_falsey
        end
      end
    end

    describe 'Scenario 6: In-place lease renewal with rate increase' do
      it 'synces scheduled rents correctly after renewal' do
        renew_lease = create(:lease,
          rental_property: property,
          lease_type: :term,
          commencement_date: Date.parse("2026-01-01"),
          termination_date: Date.parse("2026-03-31"),
          annual_rental_amount: 12000 # $1000/mo
        )
        Leases::ScheduledRentSyncService.call(renew_lease, previously_new_record: true)

        expect(renew_lease.scheduled_rents.count).to eq(3)
        expect(renew_lease.scheduled_rents.order(:due_date).map(&:amount).map(&:to_f)).to eq([ 1000.0, 1000.0, 1000.0 ])

        # Renew in-place with rate increase ($1200/mo) for another 3 months
        renew_lease.update!(
          termination_date: Date.parse("2026-06-30"),
          annual_rental_amount: 14400 # $1200/mo
        )
        Leases::ScheduledRentSyncService.call(renew_lease)

        expect(renew_lease.scheduled_rents.count).to eq(6)
        expected_amounts = [ 1000.0, 1000.0, 1000.0, 1200.0, 1200.0, 1200.0 ]
        expect(renew_lease.scheduled_rents.order(:due_date).map(&:amount).map(&:to_f)).to eq(expected_amounts)

        create(:tenant_payment, lease: renew_lease, amount: 6600.0, payment_date: Date.parse("2026-01-01"), payment_method: "zelle")
        expect(renew_lease.balance_as_of(Date.parse("2026-06-30"))).to eq(0.0)
      end
    end

    describe 'Scenario 7: In-place lease conversion from term to month-to-month' do
      it 'generates rolling forward rents' do
        conv_lease = create(:lease,
          rental_property: property,
          lease_type: :term,
          commencement_date: Date.parse("2026-01-01"),
          termination_date: Date.parse("2026-03-31"),
          annual_rental_amount: 12000 # $1000/mo
        )
        Leases::ScheduledRentSyncService.call(conv_lease, previously_new_record: true)
        expect(conv_lease.scheduled_rents.count).to eq(3)

        travel_to Date.parse("2026-04-01") do
          conv_lease.update!(
            lease_type: :month_to_month,
            termination_date: nil
          )
          Leases::ScheduledRentSyncService.call(conv_lease)
          expect(conv_lease.scheduled_rents.count).to be >= 15
        end
      end
    end
  end

  describe 'active scope and predicate' do
    let(:user) { create(:user) }
    let(:property) { create(:rental_property, user: user) }

    it 'determines if a lease is active as of a date' do
      # 1. Lease with commencement date in the future
      future_lease = create(:lease,
        rental_property: property,
        commencement_date: Date.current + 1.day,
        termination_date: Date.current + 1.month,
        lease_type: :term
      )
      expect(future_lease.active?).to be_falsey

      # 2. Lease with commencement in the past and no termination date
      ongoing_lease = create(:lease,
        rental_property: property,
        commencement_date: Date.current - 1.day,
        termination_date: nil,
        lease_type: :month_to_month
      )
      expect(ongoing_lease.active?).to be_truthy

      # 3. Lease with commencement in past and termination in future
      current_lease = create(:lease,
        rental_property: property,
        commencement_date: Date.current - 1.day,
        termination_date: Date.current + 1.day,
        lease_type: :term
      )
      expect(current_lease.active?).to be_truthy

      # 4. Lease with termination in the past
      past_lease = create(:lease,
        rental_property: property,
        commencement_date: Date.current - 2.days,
        termination_date: Date.current - 1.day,
        lease_type: :term
      )
      expect(past_lease.active?).to be_falsey

      # Test the scope
      active_leases = Lease.active
      expect(active_leases).to include(ongoing_lease)
      expect(active_leases).to include(current_lease)
      expect(active_leases).not_to include(future_lease)
      expect(active_leases).not_to include(past_lease)
    end

    it 'returns false when commencement date is missing' do
      lease = build(:lease, commencement_date: nil)

      expect(lease.active?).to be(false)
    end
  end
end
