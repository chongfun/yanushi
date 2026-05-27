require 'rails_helper'

RSpec.describe TenantPayment, type: :model do
  describe 'associations' do
    it { should belong_to(:lease) }
    it { should belong_to(:user) }
  end

  describe 'validations' do
    it { should validate_presence_of(:amount) }
    it { should validate_numericality_of(:amount).is_greater_than(0) }
    it { should validate_presence_of(:payment_date) }
    it { should validate_presence_of(:payment_method) }

    describe 'transaction number validation' do
      it { should allow_value('TXN-123_abc').for(:transaction_number) }
      it { should_not allow_value('TXN 123!').for(:transaction_number).with_message('must be alphanumeric with dashes or underscores') }
      it { should validate_length_of(:transaction_number).is_at_most(50) }
    end

    describe 'uniqueness and user scoping' do
      let(:user_one) { create(:user) }
      let(:user_two) { create(:user) }
      let(:property_one) { create(:rental_property, user: user_one) }
      let(:property_two) { create(:rental_property, user: user_two) }
      let(:lease_one) { create(:lease, rental_property: property_one) }
      let(:lease_two) { create(:lease, rental_property: property_two) }

      it 'assigns user from lease on validation' do
        tp = build(:tenant_payment, lease: lease_one, user: nil)
        expect(tp).to be_valid
        expect(tp.user).to eq(user_one)
      end

      it 'validates that user matches lease owner' do
        tp = build(:tenant_payment, lease: lease_one, user: user_two)
        expect(tp).not_to be_valid
        expect(tp.errors[:user]).to include('must match the lease owner')
      end

      it 'allows same transaction number for different users' do
        create(:tenant_payment, lease: lease_one, amount: 500, payment_method: "zelle", transaction_number: "SHARED123")
        payment = build(:tenant_payment, lease: lease_two, amount: 500, payment_method: "zelle", transaction_number: "SHARED123")
        expect(payment).to be_valid
      end

      it 'rejects duplicate transaction number for same user and payment method' do
        create(:tenant_payment, lease: lease_one, amount: 500, payment_method: "zelle", transaction_number: "DUPLICATE123")
        payment = build(:tenant_payment, lease: lease_one, amount: 500, payment_method: "zelle", transaction_number: "DUPLICATE123")
        expect(payment).not_to be_valid
        expect(payment.errors[:transaction_number]).to include('has already been taken')
      end

      it 'allows same transaction number for same user but different payment method' do
        create(:tenant_payment, lease: lease_one, amount: 500, payment_method: "zelle", transaction_number: "SHARED123")
        payment = build(:tenant_payment, lease: lease_one, amount: 500, payment_method: "check", transaction_number: "SHARED123")
        expect(payment).to be_valid
      end

      it 'returns early from owner validation if user or lease is missing' do
        tp = TenantPayment.new(user: nil, lease: nil)
        # Should not raise error and should not add custom user matching error
        tp.valid?
        expect(tp.errors[:user]).not_to include("must match the lease owner")
      end

      it 'returns early from owner validation if user is present but lease is missing' do
        tp = TenantPayment.new(user: user_one, lease: nil)
        tp.valid?
        expect(tp.errors[:user]).not_to include("must match the lease owner")
      end
    end
  end
end
