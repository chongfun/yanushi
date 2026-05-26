require 'rails_helper'

RSpec.describe "Leases", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:other_property) { create(:rental_property, user: other_user) }
  let!(:lease) { create(:lease, rental_property: property) }

  before do
    sign_in_as(user)
  end

  describe "GET /index" do
    it "renders a successful response" do
      get leases_url
      expect(response).to be_successful
    end
  end

  describe "GET /new" do
    it "filters properties and tenants to only include the current user's" do
      other_tenant = create(:tenant, user: other_user, name: "Other Tenant")

      get new_lease_url
      expect(response).to be_successful
      expect(response.body).not_to include(other_property.address)
      expect(response.body).not_to include("Other Tenant")
    end
  end

  describe "POST /create" do
    it "creates a lease with valid attributes" do
      expect {
        post leases_url, params: { lease: { annual_rental_amount: 12000, commencement_date: Date.today, late_period_days: 5, lease_type: "term", rental_property_id: property.id } }
      }.to change(Lease, :count).by(1)

      expect(response).to redirect_to(lease_url(Lease.last))
    end

    it "should not create lease with other user's property" do
      expect {
        post leases_url, params: { lease: { annual_rental_amount: 10000, commencement_date: Date.today, lease_type: "term", rental_property_id: other_property.id } }
      }.not_to change(Lease, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "should not create lease with other user's tenant" do
      other_tenant = create(:tenant, user: other_user)

      expect {
        post leases_url, params: {
          lease: {
            annual_rental_amount: 10000,
            commencement_date: Date.today,
            lease_type: "term",
            rental_property_id: property.id,
            tenant_ids: [ other_tenant.id ]
          }
        }
      }.not_to change(Lease, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "renders new on validation failure" do
      expect {
        post leases_url, params: { lease: { commencement_date: nil } }
      }.not_to change(Lease, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /show" do
    it "renders a successful response" do
      get lease_url(lease)
      expect(response).to be_successful
    end
  end

  describe "GET /edit" do
    it "renders a successful response" do
      get edit_lease_url(lease)
      expect(response).to be_successful
    end
  end

  describe "PATCH /update" do
    it "updates the lease and redirects" do
      patch lease_url(lease), params: { lease: { annual_rental_amount: 15000 } }
      expect(response).to redirect_to(lease_url(lease))
      expect(lease.reload.annual_rental_amount).to eq(15000)
    end

    it "should not update lease to other user's property" do
      patch lease_url(lease), params: { lease: { rental_property_id: other_property.id } }
      expect(response).to have_http_status(:not_found)
    end

    it "should not update lease with other user's tenant" do
      other_tenant = create(:tenant, user: other_user)
      patch lease_url(lease), params: { lease: { tenant_ids: [ other_tenant.id ] } }
      expect(response).to have_http_status(:not_found)
      expect(lease.reload.tenants).not_to include(other_tenant)
    end

    it "renders edit on validation failure" do
      patch lease_url(lease), params: { lease: { commencement_date: nil } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "updates the lease without triggering scheduled rent sync if Commencement/Termination dates and Annual Rental Amount are unchanged" do
      expect(Leases::ScheduledRentSyncService).not_to receive(:call)
      patch lease_url(lease), params: { lease: { security_deposit: 1000 } }
      expect(response).to redirect_to(lease_url(lease))
      expect(lease.reload.security_deposit).to eq(1000)
    end
  end

  describe "DELETE /destroy" do
    it "destroys the lease and redirects" do
      expect {
        delete lease_url(lease)
      }.to change(Lease, :count).by(-1)

      expect(response).to redirect_to(leases_url)
    end
  end
end
