require 'rails_helper'

RSpec.describe PaymentIngestions::TenantResolver do
  let(:resolver) { PaymentIngestions::TenantResolver.new }
  let(:user) { create(:user) }

  describe '#resolve' do
    it 'returns unmatched if both display_name and username are blank' do
      result = resolver.resolve(user, nil, nil)
      expect(result).to be_failure
      expect(result.failure.status).to eq(:unmatched)
      expect(result.failure.tenant).to be_nil
    end

    it 'resolves correctly when display_name is blank but username is present' do
      tenant = create(:tenant, user: user, name: "Jane Smith")
      create(:tenant_alias, tenant: tenant, alias_name: "@janesmith")

      result = resolver.resolve(user, "", "@janesmith")
      expect(result).to be_success
      expect(result.value!.status).to eq(:matched)
      expect(result.value!.tenant).to eq(tenant)
    end
  end
end
