require 'rails_helper'

RSpec.describe "ScheduledRents", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }
  let!(:scheduled_rent) { create(:scheduled_rent, lease: lease) }

  before do
    sign_in_as(user)
  end

  describe "GET /index" do
    it "renders a successful response" do
      get scheduled_rents_url
      expect(response).to be_successful
    end
  end

  describe "GET /new" do
    it "renders a successful response" do
      get new_scheduled_rent_url
      expect(response).to be_successful
    end
  end

  describe "POST /create" do
    it "creates a new ScheduledRent" do
      expect {
        post scheduled_rents_url, params: { scheduled_rent: { amount: 1000.0, due_date: Date.today, lease_id: lease.id } }
      }.to change(ScheduledRent, :count).by(1)

      expect(response).to redirect_to(scheduled_rent_url(ScheduledRent.last))
    end

    it "renders new on validation failure" do
      expect {
        post scheduled_rents_url, params: { scheduled_rent: { amount: -50.0 } }
      }.not_to change(ScheduledRent, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /show" do
    it "renders a successful response" do
      get scheduled_rent_url(scheduled_rent)
      expect(response).to be_successful
    end
  end

  describe "GET /edit" do
    it "renders a successful response" do
      get edit_scheduled_rent_url(scheduled_rent)
      expect(response).to be_successful
    end
  end

  describe "PATCH /update" do
    it "updates the scheduled rent and redirects" do
      patch scheduled_rent_url(scheduled_rent), params: { scheduled_rent: { amount: 1200.0 } }
      expect(response).to redirect_to(scheduled_rent_url(scheduled_rent))
      expect(scheduled_rent.reload.amount).to eq(1200.0)
    end

    it "renders edit on validation failure" do
      patch scheduled_rent_url(scheduled_rent), params: { scheduled_rent: { amount: -50.0 } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /destroy" do
    it "destroys the scheduled rent and redirects" do
      expect {
        delete scheduled_rent_url(scheduled_rent)
      }.to change(ScheduledRent, :count).by(-1)

      expect(response).to redirect_to(scheduled_rents_url)
    end
  end
end
