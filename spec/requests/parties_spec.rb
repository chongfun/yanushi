require "rails_helper"

RSpec.describe "Parties", type: :request do
  let(:user) { create(:user) }
  let!(:party) { create(:party, user: user) }

  before do
    sign_in_as(user)
  end

  describe "GET /parties" do
    it "renders a successful response" do
      get parties_url
      expect(response).to be_successful
    end
  end

  describe "GET /parties/new" do
    it "renders a successful response" do
      get new_party_url
      expect(response).to be_successful
    end
  end

  describe "POST /parties" do
    it "creates a new Party (HTML & JSON)" do
      expect {
        post parties_url, params: { party: { display_name: "Jane Doe", party_type: "individual", email_address: "jane@example.com", phone_number: "555-1234", notes: "Great tenant" } }
      }.to change(Party, :count).by(1)

      expect(response).to redirect_to(party_url(Party.last))

      post parties_url(format: :json), params: { party: { display_name: "JSON Party", party_type: "organization" } }
      expect(response).to have_http_status(:created)
    end

    it "creates a party with nested aliases" do
      expect {
        expect {
          post parties_url, params: {
            party: {
              display_name: "Alicia Keys",
              party_type: "individual",
              email_address: "alicia@example.com",
              party_aliases_attributes: [
                { alias_name: "Ali Keys" },
                { alias_name: "@alicia" }
              ]
            }
          }
        }.to change(PartyAlias, :count).by(2)
      }.to change(Party, :count).by(1)

      expect(response).to redirect_to(party_url(Party.last))
    end

    it "renders new on validation failure (HTML & JSON)" do
      expect {
        post parties_url, params: { party: { display_name: "" } }
      }.not_to change(Party, :count)

      expect(response).to have_http_status(:unprocessable_content)

      post parties_url(format: :json), params: { party: { display_name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /parties/:id" do
    it "renders a successful response" do
      get party_url(party)
      expect(response).to be_successful
    end
  end

  describe "GET /parties/:id/edit" do
    it "renders a successful response" do
      get edit_party_url(party)
      expect(response).to be_successful
    end
  end

  describe "PATCH /parties/:id" do
    it "updates the party and redirects (HTML & JSON)" do
      patch party_url(party), params: { party: { display_name: "Updated Name" } }
      expect(response).to redirect_to(party_url(party))
      expect(party.reload.display_name).to eq("Updated Name")

      patch party_url(party, format: :json), params: { party: { display_name: "JSON Updated Name" } }
      expect(response).to have_http_status(:ok)
    end

    it "updates party and nested aliases (add, destroy)" do
      alias1 = create(:party_alias, party: party, alias_name: "Ali Keys")

      expect {
        patch party_url(party), params: {
          party: {
            party_aliases_attributes: {
              "0" => { id: alias1.id, alias_name: "Ali Keys", _destroy: "1" },
              "1" => { alias_name: "New Alias" }
            }
          }
        }
      }.to change(PartyAlias, :count).by(0)

      expect(response).to redirect_to(party_url(party))
      expect(party.party_aliases.exists?(id: alias1.id)).to be_falsey
      expect(party.party_aliases.exists?(alias_name: "New Alias")).to be_truthy
    end

    it "renders edit on validation failure (HTML & JSON)" do
      patch party_url(party), params: { party: { display_name: "" } }
      expect(response).to have_http_status(:unprocessable_content)

      patch party_url(party, format: :json), params: { party: { display_name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /parties/:id" do
    it "destroys an unused party and redirects (HTML & JSON)" do
      expect {
        delete party_url(party)
      }.to change(Party, :count).by(-1)

      expect(response).to redirect_to(parties_url)

      second_party = create(:party, user: user)
      delete party_url(second_party, format: :json)
      expect(response).to have_http_status(:no_content)
    end

    it "prevents deleting a party with tenancy history (HTML & JSON)" do
      property = create(:property, user: user)
      unit = create(:rentable_unit, property: property)
      tenancy = create(:tenancy, rentable_unit: unit)
      create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant")

      expect {
        delete party_url(party)
      }.not_to change(Party, :count)

      expect(response).to redirect_to(party_url(party))
      follow_redirect!
      expect(response.body).to include("Cannot delete record because dependent tenancy parties exist")

      delete party_url(party, format: :json)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
