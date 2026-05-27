require 'rails_helper'

RSpec.describe "RentalProperties", type: :request do
  let(:user) { create(:user) }
  let!(:rental_property) { create(:rental_property, user: user) }

  before do
    sign_in_as(user)
  end

  describe "GET /index" do
    it "renders a successful response" do
      get rental_properties_url
      expect(response).to be_successful
    end
  end

  describe "GET /new" do
    it "renders a successful response" do
      get new_rental_property_url
      expect(response).to be_successful
    end
  end

  describe "POST /create" do
    it "creates a new RentalProperty" do
      expect {
        post rental_properties_url, params: { rental_property: { address: "789 Pine Rd", property_type: :single_family_residence, square_footage: 1800 } }
      }.to change(RentalProperty, :count).by(1)

      expect(response).to redirect_to(rental_property_url(RentalProperty.last))
    end

    it "renders new on validation failure" do
      expect {
        post rental_properties_url, params: { rental_property: { address: "" } }
      }.not_to change(RentalProperty, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /show" do
    it "renders a successful response" do
      get rental_property_url(rental_property)
      expect(response).to be_successful
    end
  end

  describe "GET /edit" do
    it "renders a successful response" do
      get edit_rental_property_url(rental_property)
      expect(response).to be_successful
    end
  end

  describe "PATCH /update" do
    it "updates the rental property and redirects" do
      patch rental_property_url(rental_property), params: { rental_property: { address: "Updated Address" } }
      expect(response).to redirect_to(rental_property_url(rental_property))
      expect(rental_property.reload.address).to eq("Updated Address")
    end

    it "renders edit on validation failure" do
      patch rental_property_url(rental_property), params: { rental_property: { address: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /destroy" do
    it "destroys the rental property and redirects" do
      expect {
        delete rental_property_url(rental_property)
      }.to change(RentalProperty, :count).by(-1)

      expect(response).to redirect_to(rental_properties_url)
    end
  end

  describe "GET /schedule_e_pdf" do
    it "downloads schedule_e_pdf for available year" do
      get schedule_e_pdf_rental_property_url(rental_property, year: 2025)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to match(/attachment/)
    end

    it "redirects and shows alert for missing schedule_e_pdf" do
      get schedule_e_pdf_rental_property_url(rental_property, year: 2026)
      expect(response).to redirect_to(rental_property_path(rental_property, year: 2026))
      expect(flash[:alert]).to eq("No Schedule E PDF template found for year 2026")
    end

    it "defaults to current year if year parameter is not specified" do
      allow_any_instance_of(ScheduleEGenerator).to receive(:template_path).and_return(Rails.root.join("app/assets/pdfs/f1040se--2025.pdf"))
      get schedule_e_pdf_rental_property_url(rental_property)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
    end
  end

  describe "GET /schedule_e" do
    it "renders the schedule_e modal successfully" do
      get schedule_e_rental_property_url(rental_property)
      expect(response).to be_successful
    end
  end
end
