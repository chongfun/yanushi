require "rails_helper"

RSpec.describe "Properties", type: :request do
  let(:user) { create(:user) }
  let!(:property) { create(:property, user: user) }

  before do
    sign_in_as(user)
  end

  describe "GET /properties" do
    it "renders a successful response" do
      get properties_url
      expect(response).to be_successful
    end
  end

  describe "GET /properties/new" do
    it "renders a successful response" do
      get new_property_url
      expect(response).to be_successful
    end
  end

  describe "POST /properties" do
    it "creates a new Property with implicit main unit (HTML & JSON)" do
      expect {
        post properties_url, params: { property: { address: "789 Pine Rd", asset_type: "single_family", square_footage: 1800 } }
      }.to change(Property, :count).by(1).and change(RentableUnit, :count).by(1)

      expect(response).to redirect_to(property_url(Property.last))

      post properties_url(format: :json), params: { property: { address: "790 Pine Rd", asset_type: "commercial", square_footage: 2000 } }
      expect(response).to have_http_status(:created)
    end

    it "renders new on validation failure (HTML & JSON)" do
      expect {
        post properties_url, params: { property: { address: "" } }
      }.not_to change(Property, :count)

      expect(response).to have_http_status(:unprocessable_content)

      post properties_url(format: :json), params: { property: { address: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /properties/:id" do
    it "renders a successful response" do
      get property_url(property)
      expect(response).to be_successful
    end
  end

  describe "GET /properties/:id/edit" do
    it "renders a successful response" do
      get edit_property_url(property)
      expect(response).to be_successful
    end
  end

  describe "PATCH /properties/:id" do
    it "updates the property and redirects (HTML & JSON)" do
      patch property_url(property), params: { property: { address: "Updated Address" } }
      expect(response).to redirect_to(property_url(property))
      expect(property.reload.address).to eq("Updated Address")

      patch property_url(property, format: :json), params: { property: { address: "JSON Updated Address" } }
      expect(response).to have_http_status(:ok)
    end

    it "renders edit on validation failure (HTML & JSON)" do
      patch property_url(property), params: { property: { address: "" } }
      expect(response).to have_http_status(:unprocessable_content)

      patch property_url(property, format: :json), params: { property: { address: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /properties/:id" do
    it "destroys an unused property and redirects (HTML & JSON)" do
      expect {
        delete property_url(property)
      }.to change(Property, :count).by(-1)

      expect(response).to redirect_to(properties_url)

      second_property = create(:property, user: user)
      delete property_url(second_property, format: :json)
      expect(response).to have_http_status(:no_content)
    end

    it "prevents deleting a property with expense history (HTML & JSON)" do
      create(:expense, :posted, property: property, amount_cents: 25_000, paid_on: Date.current)

      expect {
        delete property_url(property)
      }.not_to change(Property, :count)

      expect(response).to redirect_to(property_url(property))
      follow_redirect!
      expect(response.body).to include("Cannot delete record because dependent expenses exist")

      delete property_url(property, format: :json)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /properties/:id/schedule_e_pdf" do
    it "downloads schedule_e_pdf for available year" do
      get schedule_e_pdf_property_url(property, year: 2025)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to match(/attachment/)
    end

    it "redirects and shows alert for missing schedule_e_pdf" do
      get schedule_e_pdf_property_url(property, year: 2026)
      expect(response).to redirect_to(property_path(property, year: 2026))
      expect(flash[:alert]).to eq("No Schedule E PDF template found for year 2026")
    end

    it "defaults to current year if year parameter is not specified" do
      allow_any_instance_of(ScheduleEGenerator).to receive(:template_path).and_return(Rails.root.join("app/assets/pdfs/f1040se--2025.pdf"))
      get schedule_e_pdf_property_url(property)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
    end
  end

  describe "GET /properties/:id/schedule_e" do
    it "renders the schedule_e modal successfully" do
      get schedule_e_property_url(property)
      expect(response).to be_successful
    end
  end
end
