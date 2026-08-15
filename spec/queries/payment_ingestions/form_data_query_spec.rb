require "rails_helper"

RSpec.describe PaymentIngestions::FormDataQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }

  it "returns party and tenancy form data scoped to the user" do
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: Date.current)
    other_user = create(:user)
    other_property = create(:property, user: other_user)
    other_unit = create(:rentable_unit, property: other_property)
    other_tenancy = create(:tenancy, rentable_unit: other_unit)
    other_party = create(:party, user: other_user)
    create(:tenancy_party, tenancy: other_tenancy, party: other_party, role: "tenant", effective_from: Date.current)

    result = described_class.new(user: user).call

    expect(result.parties).to contain_exactly(party)
    expect(result.tenancies).to contain_exactly(tenancy)
    expect(result.party_tenancies_map[party.id]).to eq([ tenancy.id ])
    expect(result.tenancy_parties_map[tenancy.id]).to eq([ party.id ])
  end
end
