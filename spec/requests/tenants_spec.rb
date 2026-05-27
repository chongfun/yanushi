require 'rails_helper'

RSpec.describe "Tenants", type: :request do
  let(:user) { create(:user) }
  let!(:tenant) { create(:tenant, user: user) }

  before do
    sign_in_as(user)
  end

  describe "GET /index" do
    it "renders a successful response" do
      get tenants_url
      expect(response).to be_successful
    end
  end

  describe "GET /new" do
    it "renders a successful response" do
      get new_tenant_url
      expect(response).to be_successful
    end
  end

  describe "POST /create" do
    it "creates a new Tenant" do
      expect {
        post tenants_url, params: { tenant: { email_address: "tenant@example.com", mailing_address: "456 Oak Rd", name: "Jane Doe", phone_number: "555-1234" } }
      }.to change(Tenant, :count).by(1)

      expect(response).to redirect_to(tenant_url(Tenant.last))
    end

    it "creates a tenant with nested aliases" do
      expect {
        expect {
          post tenants_url, params: {
            tenant: {
              name: "Alicia Keys",
              email_address: "alicia@example.com",
              tenant_aliases_attributes: [
                { alias_name: "Ali Keys" },
                { alias_name: "@alicia" }
              ]
            }
          }
        }.to change(TenantAlias, :count).by(2)
      }.to change(Tenant, :count).by(1)

      expect(response).to redirect_to(tenant_url(Tenant.last))
    end

    it "renders new on validation failure" do
      expect {
        post tenants_url, params: { tenant: { name: "" } }
      }.not_to change(Tenant, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /show" do
    it "renders a successful response" do
      get tenant_url(tenant)
      expect(response).to be_successful
    end
  end

  describe "GET /edit" do
    it "renders a successful response" do
      get edit_tenant_url(tenant)
      expect(response).to be_successful
    end
  end

  describe "PATCH /update" do
    it "updates the tenant and redirects" do
      patch tenant_url(tenant), params: { tenant: { name: "Updated Name" } }
      expect(response).to redirect_to(tenant_url(tenant))
      expect(tenant.reload.name).to eq("Updated Name")
    end

    it "updates tenant and nested aliases (add, destroy)" do
      alias1 = create(:tenant_alias, tenant: tenant, alias_name: "Ali Keys")

      # Update: edit/destroy existing, add new
      expect {
        patch tenant_url(tenant), params: {
          tenant: {
            tenant_aliases_attributes: {
              "0" => { id: alias1.id, alias_name: "Ali Keys", _destroy: "1" },
              "1" => { alias_name: "New Alias" }
            }
          }
        }
      }.to change(TenantAlias, :count).by(0) # 1 added, 1 destroyed

      expect(response).to redirect_to(tenant_url(tenant))
      expect(tenant.tenant_aliases.exists?(id: alias1.id)).to be_falsey
      expect(tenant.tenant_aliases.exists?(alias_name: "New Alias")).to be_truthy
    end

    it "renders edit on validation failure" do
      patch tenant_url(tenant), params: { tenant: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "DELETE /destroy" do
    it "destroys the tenant and redirects" do
      expect {
        delete tenant_url(tenant)
      }.to change(Tenant, :count).by(-1)

      expect(response).to redirect_to(tenants_url)
    end
  end
end
