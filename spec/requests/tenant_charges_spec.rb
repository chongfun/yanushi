require 'rails_helper'

RSpec.describe "TenantCharges", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }
  let(:expense) { create(:expense, rental_property: property) }
  let!(:tenant_charge) { create(:tenant_charge, lease: lease, expense: expense) }

  before do
    sign_in_as(user)
  end

  describe "GET /show" do
    it "renders a successful response" do
      get tenant_charge_url(tenant_charge)
      expect(response).to be_successful
    end

    it "should not show another user's tenant_charge" do
      other_property = create(:rental_property, user: other_user)
      other_lease = create(:lease, rental_property: other_property)
      other_expense = create(:expense, rental_property: other_property)
      other_charge = create(:tenant_charge, lease: other_lease, expense: other_expense)

      get tenant_charge_url(other_charge)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /destroy" do
    it "destroys the tenant charge and redirects" do
      expect {
        delete tenant_charge_url(tenant_charge)
      }.to change(TenantCharge, :count).by(-1)

      expect(response).to redirect_to(expenses_url)
    end

    it "should not destroy another user's tenant_charge" do
      other_property = create(:rental_property, user: other_user)
      other_lease = create(:lease, rental_property: other_property)
      other_expense = create(:expense, rental_property: other_property)
      other_charge = create(:tenant_charge, lease: other_lease, expense: other_expense)

      expect {
        delete tenant_charge_url(other_charge)
      }.not_to change(TenantCharge, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
