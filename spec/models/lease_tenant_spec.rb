require 'rails_helper'

RSpec.describe LeaseTenant, type: :model do
  describe 'associations' do
    it { should belong_to(:lease) }
    it { should belong_to(:tenant) }
  end

  describe 'validations' do
    let(:user_one) { create(:user) }
    let(:user_two) { create(:user) }
    let(:property) { create(:rental_property, user: user_one) }
    let(:lease) { create(:lease, rental_property: property) }

    context 'when the tenant belongs to the same user' do
      it 'is valid' do
        same_tenant = create(:tenant, user: user_one, name: "Same Tenant")
        lease_tenant = LeaseTenant.new(lease: lease, tenant: same_tenant)

        expect(lease_tenant).to be_valid
      end
    end

    context 'when the tenant does not belong to the same user' do
      it 'is invalid' do
        other_tenant = create(:tenant, user: user_two, name: "Other Tenant")
        lease_tenant = LeaseTenant.new(lease: lease, tenant: other_tenant)

        expect(lease_tenant).not_to be_valid
        expect(lease_tenant.errors[:tenant]).to include("must belong to the same user as the lease")
      end
    end

    it 'returns early and does not validate if lease or tenant or user_id is missing' do
      lease_tenant = LeaseTenant.new(lease: nil, tenant: nil)
      expect(lease_tenant.valid?).to be_falsey # fails database presence validation, but should not raise errors or add specific owner matching errors
      expect(lease_tenant.errors[:tenant]).not_to include("must belong to the same user as the lease")
    end

    it 'returns early if lease is present but tenant is missing' do
      lease_tenant = LeaseTenant.new(lease: lease, tenant: nil)
      expect(lease_tenant.valid?).to be_falsey
      expect(lease_tenant.errors[:tenant]).not_to include("must belong to the same user as the lease")
    end
  end
end
