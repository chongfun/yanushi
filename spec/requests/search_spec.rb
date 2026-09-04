require "rails_helper"

RSpec.describe "Search", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /search" do
    context "when unauthenticated" do
      it "requires a sign in" do
        get search_url(q: "maple")

        expect(response).to redirect_to(new_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in_as(user) }

      it "prompts with what is absent and what to do next when no query has been entered" do
        get search_url

        expect(response).to be_successful
        expect(response.body).to include("Nothing searched yet")
        expect(response.body).to include("Type a name or an address above")
        expect(response.body).to include("Browse portfolio")
      end

      it "asks for more characters below the minimum length instead of matching everything" do
        create(:property, user: user, address: "1 Maple Court")

        get search_url(q: "m")

        expect(response).to be_successful
        expect(response.body).to include("Search is too short")
        expect(response.body).to include("Enter at least 2 characters")
        expect(response.body).not_to include("1 Maple Court")
      end

      it "ignores surrounding whitespace when measuring the query" do
        get search_url(q: "  m  ")

        expect(response.body).to include("Search is too short")
      end

      it "says what is absent and what to do next when nothing matches" do
        create(:property, user: user, address: "1 Maple Court")

        get search_url(q: "zzzz")

        expect(response).to be_successful
        expect(response.body).to include("No matches for")
        expect(response.body).to include("Check the spelling")
        expect(response.body).to include("Browse portfolio")
      end

      it "groups matches by kind with a count per group and links every row to its record" do
        property = create(:property, user: user, address: "12 Maple Court")
        unit = create(:rentable_unit, property: property, name: "Maple rear cottage", unit_identifier: "MC-2")
        tenancy = create(:tenancy, rentable_unit: unit, commencement_date: Date.current - 1.month, termination_date: nil, agreement_type: "month_to_month")
        party = create(:party, user: user, display_name: "Maple Holdings LLC", party_type: "organization")
        create(:tenancy_party, tenancy: tenancy, party: party)

        get search_url(q: "maple")

        expect(response).to be_successful
        expect(response.body).to include("Properties")
        expect(response.body).to include("Units")
        expect(response.body).to include("Tenancies")
        expect(response.body).to include("Parties")

        expect(response.body).to include("4 matches for")
        expect(response.body).to include(property_path(property))
        expect(response.body).to include(tenancy_path(tenancy))
        expect(response.body).to include(party_path(party))
        expect(response.body).to include("Maple rear cottage (MC-2)")
        expect(response.body).to include("Active")
      end

      it "finds a tenancy by its tenant's name, its unit, and its property address" do
        property = create(:property, user: user, address: "88 Birch Row")
        unit = create(:rentable_unit, property: property, name: "Garden flat", unit_identifier: "GF")
        tenancy = create(:tenancy, rentable_unit: unit)
        create(:tenancy_party, tenancy: tenancy, party: create(:party, user: user, display_name: "Priya Raman"))

        get search_url(q: "priya")
        expect(response.body).to include(tenancy_path(tenancy))
        expect(response.body).to include("Priya Raman")

        get search_url(q: "birch")
        expect(response.body).to include(tenancy_path(tenancy))

        get search_url(q: "garden fl")
        expect(response.body).to include(tenancy_path(tenancy))
      end

      it "finds a party by alias, email, and phone" do
        party = create(:party, user: user, display_name: "Robert Okonkwo", email_address: "bobby@example.org", phone_number: "555-0142")
        create(:party_alias, party: party, alias_name: "Bobby O")

        get search_url(q: "bobby o")
        expect(response.body).to include(party_path(party))
        expect(response.body).to include("aka Bobby O")

        get search_url(q: "bobby@example")
        expect(response.body).to include(party_path(party))

        get search_url(q: "555-0142")
        expect(response.body).to include(party_path(party))
      end

      it "caps each group and links to the index for the rest" do
        7.times { |n| create(:property, user: user, address: "#{n} Cedar Way") }

        get search_url(q: "cedar")

        expect(response).to be_successful
        expect(response.body).to include("7 matches")
        expect(response.body).to include("Showing the first")
        expect(response.body).to include("See all properties")
        expect(response.body.scan(%r{href="/properties/\d+"}).size).to eq(5)
      end

      it "keeps the query in the URL so the result page survives a refresh and can be shared" do
        create(:property, user: user, address: "5 Willow Lane")

        get search_url(q: "willow")

        expect(response).to be_successful
        expect(response.body).to include("value=\"willow\"")
        expect(response.body).to include("5 Willow Lane")
      end

      it "treats ILIKE wildcards as literal characters" do
        plain = create(:property, user: user, address: "3 Ash Street")
        literal = create(:property, user: user, address: "3 Ash % Street")

        get search_url(q: "ash %")

        expect(response.body).to include(literal.address)
        expect(response.body).not_to include(plain.address)
      end

      it "cannot be used to see another user's records" do
        own_property = create(:property, user: user, address: "1 Sable Street")

        foreign_property = create(:property, user: other_user, address: "999 Sable Secret Avenue")
        foreign_unit = create(:rentable_unit, property: foreign_property, name: "Sable hidden unit", unit_identifier: "SABLE-X")
        foreign_tenancy = create(:tenancy, rentable_unit: foreign_unit)
        foreign_party = create(:party, user: other_user, display_name: "Sable Private Person", email_address: "sable-private@example.org", phone_number: "555-9999")
        create(:party_alias, party: foreign_party, alias_name: "Sable Alias")
        create(:tenancy_party, tenancy: foreign_tenancy, party: foreign_party)

        get search_url(q: "sable")

        expect(response).to be_successful
        expect(response.body).to include("1 Sable Street")
        expect(response.body).to include(%(href="#{property_path(own_property)}"))

        expect(response.body).not_to include("999 Sable Secret Avenue")
        expect(response.body).not_to include("Sable hidden unit")
        expect(response.body).not_to include("SABLE-X")
        expect(response.body).not_to include("Sable Private Person")
        expect(response.body).not_to include("Sable Alias")
        expect(response.body).not_to include("sable-private@example.org")
        expect(response.body).not_to include(%(href="#{property_path(foreign_property)}"))
        expect(response.body).not_to include(%(href="#{tenancy_path(foreign_tenancy)}"))
        expect(response.body).not_to include(%(href="#{party_path(foreign_party)}"))
        expect(response.body).to include("1 match for")
      end
    end
  end

  describe "the shell affordance" do
    before { sign_in_as(user) }

    it "offers a labelled search field in the sidebar and a search link in the mobile top bar" do
      get root_url

      expect(response).to be_successful
      expect(response.body).to include("for=\"sidebar-search-q\"")
      expect(response.body).to include("id=\"sidebar-search-q\"")
      expect(response.body).to include("action=\"/search\"")
      expect(response.body).to include("href=\"/search\"")
    end

    it "does not add search to the five primary navigation items" do
      get root_url

      primary_nav = Nokogiri::HTML(response.body).css("nav[aria-label='Primary']")

      expect(primary_nav).to be_present
      expect(primary_nav.text).not_to include("Search")
    end
  end
end
