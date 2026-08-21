require "rails_helper"

RSpec.describe "RentableUnits", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let!(:rentable_unit) { create(:rentable_unit, property: property) }

  before do
    sign_in_as(user)
  end

  describe "GET /properties/:property_id/rentable_units/new" do
    it "renders a successful response" do
      get new_property_rentable_unit_url(property)
      expect(response).to be_successful
    end
  end

  describe "POST /properties/:property_id/rentable_units" do
    it "creates a new RentableUnit (HTML & JSON)" do
      expect {
        post property_rentable_units_url(property), params: {
          rentable_unit: { name: "Unit 202", unit_identifier: "202", square_footage: 900 }
        }
      }.to change(RentableUnit, :count).by(1)

      expect(response).to redirect_to(property_url(property))

      post property_rentable_units_url(property, format: :json), params: {
        rentable_unit: { name: "Unit 203", unit_identifier: "203", square_footage: 950 }
      }
      expect(response).to have_http_status(:created)
    end

    it "renders new on validation failure (HTML & JSON)" do
      expect {
        post property_rentable_units_url(property), params: {
          rentable_unit: { name: "" }
        }
      }.not_to change(RentableUnit, :count)

      expect(response).to have_http_status(:unprocessable_content)

      post property_rentable_units_url(property, format: :json), params: {
        rentable_unit: { name: "" }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /properties/:property_id/rentable_units/:id/edit" do
    it "renders a successful response" do
      get edit_property_rentable_unit_url(property, rentable_unit)
      expect(response).to be_successful
    end
  end

  describe "PATCH /properties/:property_id/rentable_units/:id" do
    it "updates the unit and redirects (HTML & JSON)" do
      patch property_rentable_unit_url(property, rentable_unit), params: {
        rentable_unit: { name: "Updated Unit Name" }
      }
      expect(response).to redirect_to(property_url(property))
      expect(rentable_unit.reload.name).to eq("Updated Unit Name")

      patch property_rentable_unit_url(property, rentable_unit, format: :json), params: {
        rentable_unit: { name: "JSON Updated Unit" }
      }
      expect(response).to have_http_status(:ok)
    end

    it "renders edit on validation failure (HTML & JSON)" do
      patch property_rentable_unit_url(property, rentable_unit), params: {
        rentable_unit: { name: "" }
      }
      expect(response).to have_http_status(:unprocessable_content)

      patch property_rentable_unit_url(property, rentable_unit, format: :json), params: {
        rentable_unit: { name: "" }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /properties/:property_id/rentable_units/:id" do
    it "destroys an unused unit and redirects (HTML & JSON)" do
      expect {
        delete property_rentable_unit_url(property, rentable_unit)
      }.to change(RentableUnit, :count).by(-1)

      expect(response).to redirect_to(property_url(property))

      second_unit = create(:rentable_unit, property: property, name: "Second Unit")
      delete property_rentable_unit_url(property, second_unit, format: :json)
      expect(response).to have_http_status(:no_content)
    end

    it "deactivates rather than destroys a unit that has tenancy history (HTML & JSON)" do
      create(:tenancy, rentable_unit: rentable_unit)

      expect {
        delete property_rentable_unit_url(property, rentable_unit)
      }.not_to change(RentableUnit, :count)

      expect(rentable_unit.reload.active).to be(false)
      expect(response).to redirect_to(property_url(property))
      follow_redirect!
      expect(response.body).to include("deactivated instead of deleted")

      used_unit_2 = create(:rentable_unit, property: property, name: "Used Unit 2")
      create(:tenancy, rentable_unit: used_unit_2)

      delete property_rentable_unit_url(property, used_unit_2, format: :json)
      expect(response).to have_http_status(:ok)
      expect(used_unit_2.reload.active).to be(false)
    end
  end
end
