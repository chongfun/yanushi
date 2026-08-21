require "rails_helper"

RSpec.describe "TenantCharges", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:expense) { create(:expense, property: property) }
  let!(:tenant_charge) { create(:tenant_charge, tenancy: tenancy, expense: expense) }

  before do
    sign_in_as(user)
  end

  describe "GET /tenant_charges/:id" do
    it "renders a successful response" do
      get tenant_charge_url(tenant_charge)
      expect(response).to be_successful
    end

    it "should not show another user's tenant_charge" do
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_expense = create(:expense, property: other_property)
      other_charge = create(:tenant_charge, tenancy: other_tenancy, expense: other_expense)

      get tenant_charge_url(other_charge)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /tenant_charges/:id" do
    it "destroys the tenant charge and redirects" do
      expect {
        delete tenant_charge_url(tenant_charge)
      }.to change(TenantCharge, :count).by(-1)

      expect(response).to redirect_to(expenses_url)
    end

    it "should not destroy another user's tenant_charge" do
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_expense = create(:expense, property: other_property)
      other_charge = create(:tenant_charge, tenancy: other_tenancy, expense: other_expense)

      expect {
        delete tenant_charge_url(other_charge)
      }.not_to change(TenantCharge, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
