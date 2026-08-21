require "rails_helper"

RSpec.describe "ScheduledRents", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let!(:scheduled_rent) { create(:scheduled_rent, tenancy: tenancy) }

  before do
    sign_in_as(user)
  end

  describe "GET /scheduled_rents" do
    it "renders a successful response" do
      get scheduled_rents_url
      expect(response).to be_successful
    end
  end

  describe "GET /scheduled_rents/:id" do
    it "renders a successful response for owner" do
      get scheduled_rent_url(scheduled_rent)
      expect(response).to be_successful
    end

    it "returns 404 for another user's scheduled rent" do
      other_prop = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_prop)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_sr = create(:scheduled_rent, tenancy: other_tenancy)

      get scheduled_rent_url(other_sr)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Read-only enforcement (no writable routes)" do
    it "does not have routes for new, create, edit, update, destroy" do
      get "/scheduled_rents/new"
      expect(response).to have_http_status(:not_found)

      post "/scheduled_rents", params: { scheduled_rent: { amount: 1000.0 } }
      expect(response).to have_http_status(:not_found)

      get "/scheduled_rents/#{scheduled_rent.id}/edit"
      expect(response).to have_http_status(:not_found)

      patch "/scheduled_rents/#{scheduled_rent.id}", params: { scheduled_rent: { amount: 1000.0 } }
      expect(response).to have_http_status(:not_found)

      delete "/scheduled_rents/#{scheduled_rent.id}"
      expect(response).to have_http_status(:not_found)
    end
  end
end
