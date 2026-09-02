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

  it "preloads party_aliases on parties to avoid N+1 queries during alias proposal evaluation" do
    5.times do |i|
      p = create(:party, user: user, display_name: "Tenant #{i}")
      create(:party_alias, party: p, alias_name: "ALIAS #{i}")
    end

    result = described_class.new(user: user).call
    parties = result.parties.to_a
    expect(parties.first.association(:party_aliases)).to be_loaded

    # Evaluating alias candidates across all parties should perform zero additional SQL queries
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end

    begin
      parties.each do |p|
        p.alias_candidate?("Test Payer")
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    expect(queries).to be_empty
  end
end
