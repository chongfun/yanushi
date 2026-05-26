require 'rails_helper'

RSpec.describe User, type: :model do
  describe 'associations' do
    it { should have_many(:sessions).dependent(:destroy) }
    it { should have_many(:rental_properties).dependent(:destroy) }
    it { should have_many(:leases).through(:rental_properties) }
    it { should have_many(:expenses).through(:rental_properties) }
    it { should have_many(:scheduled_rents).through(:leases) }
    it { should have_many(:tenant_payments).through(:leases) }
    it { should have_many(:tenant_charges).through(:leases) }
    it { should have_many(:tenants).dependent(:destroy) }
    it { should have_many(:payment_ingestions).dependent(:destroy) }
    it { should have_many(:payment_documents).dependent(:destroy) }
  end

  describe 'validations' do
    subject { build(:user) }
    it { should validate_presence_of(:email) }
    it { should validate_uniqueness_of(:email).case_insensitive }
    it { should validate_presence_of(:password_digest) }
  end

  describe 'email normalization' do
    it 'downcases and strips email' do
      user = User.new(email: " DOWNCASED@EXAMPLE.COM ")
      expect(user.email).to eq("downcased@example.com")
    end
  end
end
