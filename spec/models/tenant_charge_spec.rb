require 'rails_helper'

RSpec.describe TenantCharge, type: :model do
  describe 'associations' do
    it { should belong_to(:lease) }
    it { should belong_to(:expense) }
  end

  describe 'validations' do
    it { should validate_presence_of(:amount) }
    it { should validate_numericality_of(:amount).is_greater_than(0) }
    it { should validate_presence_of(:charge_date) }

    it 'is valid with all required fields' do
      tc = build(:tenant_charge)
      expect(tc).to be_valid
    end

    it 'is invalid with non-positive amount' do
      tc = build(:tenant_charge, amount: -5.0)
      expect(tc).not_to be_valid
    end
  end
end
