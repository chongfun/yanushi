require 'rails_helper'

RSpec.describe RentalProperty, type: :model do
  describe 'associations' do
    it { should belong_to(:user) }
    it { should have_many(:leases).dependent(:destroy) }
    it { should have_many(:scheduled_rents).through(:leases) }
    it { should have_many(:expenses).dependent(:destroy) }
    it { should have_many(:tenant_payments).through(:leases) }
    it { should have_many(:tenant_charges).through(:leases) }
  end

  describe 'enums' do
    it { should define_enum_for(:property_type).with_values(
      single_family_residence: 1,
      multi_family_residence: 2,
      vacation_or_short_term_rental: 3,
      commercial: 4,
      land: 5,
      royalties: 6,
      self_rental: 7,
      other: 8
    ) }
  end

  describe 'validations' do
    it { should validate_presence_of(:address) }
  end

  describe '#active_years' do
    let(:user) { create(:user) }
    let(:property) { create(:rental_property, user: user) }

    it 'always includes the current year' do
      expect(property.active_years).to include(Date.current.year)
    end

    it 'includes years with associated data' do
      lease = create(:lease, rental_property: property)
      create(:scheduled_rent, lease: lease, due_date: Date.new(2026, 4, 28))

      expect(property.active_years).to include(2026)
    end

    it 'includes custom additional years if passed' do
      expect(property.active_years([ 2020 ])).to include(2020)
    end

    it 'does not include invalid additional years (like zero)' do
      expect(property.active_years([ 0, nil, 'abc' ])).to eq([ Date.current.year ])
    end
  end

  describe '#financial_items' do
    let(:user) { create(:user) }
    let(:property) { create(:rental_property, user: user) }
    let(:lease) { create(:lease, rental_property: property) }

    it 'returns sorted financial items for a given year' do
      sr = create(:scheduled_rent, lease: lease, due_date: Date.new(2026, 5, 1), amount: 1000.0)
      tp = create(:tenant_payment, lease: lease, payment_date: Date.new(2026, 5, 5), amount: 1000.0)
      exp = create(:expense, rental_property: property, expense_date: Date.new(2026, 5, 10), amount: 50.0)
      tc = create(:tenant_charge, lease: lease, expense: exp, charge_date: Date.new(2026, 5, 10), amount: 50.0)

      items = property.financial_items(2026)
      expect(items.size).to eq(4)
      expect(items[0][:type]).to eq('Scheduled Rent')
      expect(items[1][:type]).to eq('Tenant Payment')
      expect(items[2][:type]).to eq('Tenant Charge')
      expect(items[3][:type]).to eq('Expense')
    end

    it 'returns sorted financial items when associations are preloaded' do
      sr = create(:scheduled_rent, lease: lease, due_date: Date.new(2026, 5, 1), amount: 1000.0)
      tp = create(:tenant_payment, lease: lease, payment_date: Date.new(2026, 5, 5), amount: 1000.0)
      exp = create(:expense, rental_property: property, expense_date: Date.new(2026, 5, 10), amount: 50.0)
      tc = create(:tenant_charge, lease: lease, expense: exp, charge_date: Date.new(2026, 5, 10), amount: 50.0)

      preloaded_property = RentalProperty.includes(:scheduled_rents, :tenant_payments, :tenant_charges, :expenses).find(property.id)
      expect(preloaded_property.scheduled_rents.loaded?).to be_truthy
      expect(preloaded_property.tenant_payments.loaded?).to be_truthy
      expect(preloaded_property.tenant_charges.loaded?).to be_truthy
      expect(preloaded_property.expenses.loaded?).to be_truthy

      items = preloaded_property.financial_items(2026)
      expect(items.size).to eq(4)
      expect(items[2][:type]).to eq('Tenant Charge')
    end
  end
end
