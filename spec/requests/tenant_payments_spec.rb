require "rails_helper"

RSpec.describe "TenantPayments", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:other_property) { create(:property, user: other_user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:other_unit) { create(:rentable_unit, property: other_property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:other_tenancy) { create(:tenancy, rentable_unit: other_unit) }
  let!(:tenant_payment) { create(:tenant_payment, tenancy: tenancy) }

  before do
    sign_in_as(user)
  end

  describe "GET /tenant_payments" do
    it "renders a successful response" do
      get tenant_payments_url
      expect(response).to be_successful
    end
  end

  describe "GET /tenant_payments/new" do
    it "filters tenancies to only include the current user's" do
      other_party = create(:party, user: other_user, display_name: "Other Tenant")
      create(:tenancy_party, tenancy: other_tenancy, party: other_party, role: "tenant", effective_from: Date.current)

      get new_tenant_payment_url
      expect(response).to be_successful
      expect(response.body).not_to include(other_property.address)
      expect(response.body).not_to include("Other Tenant")
    end

    it "defaults payment amount to absolute balance when balance is negative (tenant owes money)" do
      allow_any_instance_of(Tenancy).to receive(:current_balance).and_return(-600)
      get new_tenant_payment_url, params: { tenancy_id: tenancy.id }
      expect(response).to be_successful
      expect(response.body).to include('value="600"')
    end

    it "defaults payment amount to 0 when balance is positive or zero" do
      allow_any_instance_of(Tenancy).to receive(:current_balance).and_return(200)
      get new_tenant_payment_url, params: { tenancy_id: tenancy.id }
      expect(response).to be_successful
      expect(response.body).to include('value="0.0"')
    end
  end

  describe "POST /tenant_payments" do
    it "creates a new TenantPayment" do
      expect {
        post tenant_payments_url, params: { tenant_payment: { tenancy_id: tenancy.id, amount: 500, payment_date: Date.today, payment_method: "Zelle", transaction_number: "TXNTEST123" } }
      }.to change(TenantPayment, :count).by(1)

      expect(response).to redirect_to(tenant_payment_url(TenantPayment.last))
    end

    it "should not create tenant payment with other user's tenancy" do
      expect {
        post tenant_payments_url, params: { tenant_payment: { tenancy_id: other_tenancy.id, amount: 500, payment_date: Date.today, payment_method: "Zelle", transaction_number: "TXNTEST456" } }
      }.not_to change(TenantPayment, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "skips tenancy lookup if tenancy_id is not present" do
      expect {
        post tenant_payments_url, params: { tenant_payment: { tenancy_id: "", amount: 500, payment_date: Date.today, payment_method: "Zelle" } }
      }.not_to change(TenantPayment, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "handles modal-submit success with turbo_stream" do
      expect {
        post tenant_payments_url, params: {
          tenancy_id: tenancy.id,
          tenant_payment: { tenancy_id: tenancy.id, amount: 500, payment_date: Date.today, payment_method: "Zelle" }
        }, as: :turbo_stream
      }.to change(TenantPayment, :count).by(1)

      expect(response).to have_http_status(:ok)
    end

    it "handles modal-submit success with turbo_stream and blank payment_date" do
      expect {
        post tenant_payments_url, params: {
          tenancy_id: tenancy.id,
          tenant_payment: { tenancy_id: tenancy.id, amount: 500, payment_date: "", payment_method: "Zelle" }
        }, as: :turbo_stream
      }.not_to change(TenantPayment, :count)

      expect(response).to have_http_status(:ok)
    end

    it "handles modal-submit success with turbo_stream when payment_date is nil but save succeeds (triggers fallback year)" do
      tp_instance = TenantPayment.new(tenancy: tenancy, amount: 500, payment_method: "Zelle")
      allow(tp_instance).to receive(:save).and_return(true)
      allow(tp_instance).to receive(:payment_date).and_return(nil)
      allow(TenantPayment).to receive(:new).and_return(tp_instance)

      post tenant_payments_url, params: {
        tenancy_id: tenancy.id,
        tenant_payment: { tenancy_id: tenancy.id, amount: 500, payment_method: "Zelle" }
      }, as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("turbo-stream")
    end
  end

  describe "GET /tenant_payments/:id" do
    it "renders a successful HTML response" do
      get tenant_payment_url(tenant_payment)
      expect(response).to be_successful
    end

    it "renders a successful PDF response" do
      get tenant_payment_url(tenant_payment, format: :pdf)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
    end

    it "renders a successful PDF response when transaction number is missing" do
      tp_no_txn = create(:tenant_payment, tenancy: tenancy, transaction_number: nil)
      get tenant_payment_url(tp_no_txn, format: :pdf)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
    end
  end

  describe "GET /tenant_payments/:id/edit" do
    it "renders a successful response" do
      get edit_tenant_payment_url(tenant_payment)
      expect(response).to be_successful
    end
  end

  describe "PATCH /tenant_payments/:id" do
    it "updates the tenant payment and redirects" do
      patch tenant_payment_url(tenant_payment), params: { tenant_payment: { amount: 600 } }
      expect(response).to redirect_to(tenant_payment_url(tenant_payment))
      expect(tenant_payment.reload.amount).to eq(600)
    end

    it "should not update tenant payment to other user's tenancy" do
      patch tenant_payment_url(tenant_payment), params: { tenant_payment: { tenancy_id: other_tenancy.id } }
      expect(response).to have_http_status(:not_found)
    end

    it "renders edit on validation failure" do
      patch tenant_payment_url(tenant_payment), params: { tenant_payment: { amount: -50.0 } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /tenant_payments/:id" do
    it "destroys the tenant payment and redirects" do
      expect {
        delete tenant_payment_url(tenant_payment)
      }.to change(TenantPayment, :count).by(-1)

      expect(response).to redirect_to(tenant_payments_url)
    end
  end
end
