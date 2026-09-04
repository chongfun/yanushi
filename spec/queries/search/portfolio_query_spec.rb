require "rails_helper"

RSpec.describe Search::PortfolioQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  def group(result, key)
    result.groups.find { |g| g.key == key }
  end

  def count_queries
    queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA"
      next if sql.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      queries << sql
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  describe ".call" do
    it "returns an empty result below the minimum query length without touching the database" do
      create(:property, user: user, address: "1 Maple Court")

      result = nil
      queries = count_queries { result = described_class.call(user: user, query: "m") }

      expect(result.groups).to eq([])
      expect(result.total_count).to eq(0)
      expect(result.query).to eq("m")
      expect(queries).to be_empty
    end

    it "returns an empty result for a blank query" do
      result = described_class.call(user: user, query: "   ")

      expect(result.query).to eq("")
      expect(result.total_count).to eq(0)
    end

    it "matches properties by address, case-insensitively" do
      property = create(:property, user: user, address: "12 MAPLE Court")
      create(:property, user: user, address: "9 Elm Street")

      result = described_class.call(user: user, query: "maple")

      expect(group(result, :properties).records).to eq([ property ])
      expect(group(result, :properties).total_count).to eq(1)
    end

    it "matches units by name and by identifier" do
      property = create(:property, user: user, address: "12 Elm Street")
      by_name = create(:rentable_unit, property: property, name: "Coach house", unit_identifier: "CH-1")
      by_identifier = create(:rentable_unit, property: property, name: "Front flat", unit_identifier: "COACH-9")
      create(:rentable_unit, property: property, name: "Rear flat", unit_identifier: "RF-1")

      records = group(described_class.call(user: user, query: "coach"), :rentable_units).records

      expect(records).to contain_exactly(by_name, by_identifier)
    end

    it "matches tenancies by property address, unit, and tenant name, listing each tenancy once" do
      property = create(:property, user: user, address: "44 Coach Road")
      unit = create(:rentable_unit, property: property, name: "Coach flat", unit_identifier: "COACH-2")
      tenancy = create(:tenancy, rentable_unit: unit)
      create(:tenancy_party, tenancy: tenancy, party: create(:party, user: user, display_name: "Coach Company"))
      create(:tenancy_party, tenancy: tenancy, party: create(:party, user: user, display_name: "Coach Cosigner"), role: "guarantor")

      result = described_class.call(user: user, query: "coach")

      expect(group(result, :tenancies).records).to eq([ tenancy ])
      expect(group(result, :tenancies).total_count).to eq(1)
    end

    it "matches parties by display name, alias, email, and phone" do
      by_name = create(:party, user: user, display_name: "Quinn Marlowe", email_address: "q@example.org", phone_number: "555-0001")
      by_alias = create(:party, user: user, display_name: "Q. M. Holdings", email_address: "holdings@example.org", phone_number: "555-0002")
      create(:party_alias, party: by_alias, alias_name: "Marlowe Family Trust")
      by_email = create(:party, user: user, display_name: "Unrelated Name", email_address: "marlowe@example.org", phone_number: "555-0003")
      by_phone = create(:party, user: user, display_name: "Another Name", email_address: "other@example.org", phone_number: "555-MARLOWE")
      create(:party, user: user, display_name: "No Match Here", email_address: "nope@example.org", phone_number: "555-0004")

      records = group(described_class.call(user: user, query: "marlowe"), :parties).records

      expect(records).to contain_exactly(by_name, by_alias, by_email, by_phone)
    end

    it "lists a party once even when several of its aliases match" do
      party = create(:party, user: user, display_name: "Ada Nkemelu")
      create(:party_alias, party: party, alias_name: "Ada N")
      create(:party_alias, party: party, alias_name: "Ada Nkem")

      result = described_class.call(user: user, query: "ada")

      expect(group(result, :parties).records).to eq([ party ])
      expect(group(result, :parties).total_count).to eq(1)
    end

    it "caps each group at the limit while reporting the true total" do
      7.times { |n| create(:property, user: user, address: "#{n} Cedar Way") }

      result = described_class.call(user: user, query: "cedar", limit: 5)

      expect(group(result, :properties).records.size).to eq(5)
      expect(group(result, :properties).total_count).to eq(7)
      expect(result.total_count).to eq(7)
    end

    it "skips the count query when a group did not fill its cap" do
      create(:property, user: user, address: "1 Cedar Way")

      queries = count_queries { described_class.call(user: user, query: "cedar") }

      expect(queries.grep(/COUNT/).size).to eq(0)
    end

    it "treats LIKE wildcards in the query as literal characters" do
      literal = create(:property, user: user, address: "3 Ash % Street")
      create(:property, user: user, address: "3 Ash Street")

      expect(group(described_class.call(user: user, query: "ash %"), :properties).records).to eq([ literal ])
      expect(group(described_class.call(user: user, query: "as_"), :properties).records).to eq([])
    end

    it "runs a bounded number of queries and preloads what the rows render" do
      3.times do |n|
        property = create(:property, user: user, address: "#{n} Sequoia Street")
        unit = create(:rentable_unit, property: property, name: "Sequoia unit #{n}", unit_identifier: "SQ-#{n}")
        tenancy = create(:tenancy, rentable_unit: unit)
        party = create(:party, user: user, display_name: "Sequoia Tenant #{n}")
        create(:tenancy_party, tenancy: tenancy, party: party)
        create(:party_alias, party: party, alias_name: "Sequoia alias #{n}")
      end

      result = nil
      search_queries = count_queries { result = described_class.call(user: user, query: "sequoia") }

      expect(search_queries.size).to be <= 12

      render_queries = count_queries do
        group(result, :rentable_units).records.each { |unit| unit.property.address }
        group(result, :tenancies).records.each do |tenancy|
          tenancy.rentable_unit.property.address
          tenancy.all_tenant_parties.map(&:display_name)
        end
        group(result, :parties).records.each { |party| party.party_aliases.map(&:alias_name) }
      end

      expect(render_queries).to be_empty
    end

    it "is scoped to the signed-in user and cannot reach another user's records" do
      own = create(:property, user: user, address: "1 Sable Street")

      foreign_property = create(:property, user: other_user, address: "999 Sable Secret Avenue")
      foreign_unit = create(:rentable_unit, property: foreign_property, name: "Sable hidden unit", unit_identifier: "SABLE-X")
      foreign_tenancy = create(:tenancy, rentable_unit: foreign_unit)
      foreign_party = create(:party, user: other_user, display_name: "Sable Private Person")
      create(:party_alias, party: foreign_party, alias_name: "Sable Alias")
      create(:tenancy_party, tenancy: foreign_tenancy, party: foreign_party)

      result = described_class.call(user: user, query: "sable")

      expect(group(result, :properties).records).to eq([ own ])
      expect(group(result, :rentable_units).records).to eq([])
      expect(group(result, :tenancies).records).to eq([])
      expect(group(result, :parties).records).to eq([])
      expect(result.total_count).to eq(1)
    end
  end
end
