require "rails_helper"

RSpec.describe PaymentIngestions::FormDataQuery do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }
  let(:tenant) { create(:tenant, user: user) }

  it "returns tenant and lease form data scoped to the user" do
    create(:lease_tenant, lease: lease, tenant: tenant)
    other_user = create(:user)
    other_property = create(:rental_property, user: other_user)
    other_lease = create(:lease, rental_property: other_property)
    other_tenant = create(:tenant, user: other_user)
    create(:lease_tenant, lease: other_lease, tenant: other_tenant)

    result = described_class.new(user: user).call

    expect(result.tenants).to contain_exactly(tenant)
    expect(result.leases).to contain_exactly(lease)
    expect(result.tenant_leases_map[tenant.id]).to eq([ lease.id ])
    expect(result.lease_tenants_map[lease.id]).to eq([ tenant.id ])
  end
end
