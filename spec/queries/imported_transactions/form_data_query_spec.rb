require "rails_helper"

RSpec.describe ImportedTransactions::FormDataQuery do
  let(:user) { create(:user) }
  let(:party) { create(:party, user: user, display_name: "John Doe") }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, commencement_date: Date.current) }
  let!(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant") }

  it "returns parties, tenancies, and cross-lookup maps" do
    result = described_class.new(user: user).call

    expect(result.parties).to include(party)
    expect(result.tenancies).to include(tenancy)
    expect(result.party_tenancies_map[party.id]).to include(tenancy.id)
    expect(result.tenancy_parties_map[tenancy.id]).to include(party.id)
  end
end
