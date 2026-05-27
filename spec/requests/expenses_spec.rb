require 'rails_helper'

RSpec.describe "Expenses", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:other_property) { create(:rental_property, user: other_user) }
  let(:lease) { create(:lease, rental_property: property) }
  let(:other_lease) { create(:lease, rental_property: other_property) }
  let!(:expense) { create(:expense, rental_property: property) }

  before do
    sign_in_as(user)
  end

  describe "GET /index" do
    it "renders a successful response" do
      get expenses_url
      expect(response).to be_successful
    end
  end

  describe "GET /new" do
    it "renders a successful response and filters out other user data" do
      other_tenant = create(:tenant, user: other_user, name: "Other Tenant")
      get new_expense_url
      expect(response).to be_successful
      expect(response.body).not_to include(other_property.address)
      expect(response.body).not_to include("Other Tenant")
    end

    it "sets rental property when rental_property_id is passed" do
      get new_expense_url, params: { rental_property_id: property.id }
      expect(response).to be_successful
      expect(response.body).to include(property.address)
    end
  end

  describe "POST /create" do
    it "creates an expense with valid parameters" do
      expect {
        post expenses_url, params: { expense: { amount: 100.00, category: "repairs", description: "Faucet", expense_date: Date.today, rental_property_id: property.id } }
      }.to change(Expense, :count).by(1)

      expect(response).to redirect_to(expense_url(Expense.last))
    end

    it "fails to create an expense when rental_property_id is blank" do
      expect {
        post expenses_url, params: { expense: { amount: 100.00, category: "repairs", description: "Faucet", expense_date: Date.today, rental_property_id: "" } }
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "handles modal-submit success with turbo_stream" do
      expect {
        post expenses_url, params: {
          rental_property_id: property.id,
          expense: { amount: 100.00, category: "repairs", description: "Faucet", expense_date: Date.today, rental_property_id: property.id }
        }, as: :turbo_stream
      }.to change(Expense, :count).by(1)

      expect(response).to have_http_status(:ok)
    end

    it "handles modal-submit success with turbo_stream and empty expense_date" do
      allow(Expenses::TenantChargeService).to receive(:call).and_return(true)
      allow_any_instance_of(RentalProperty).to receive(:financial_items).and_return([])
      allow_any_instance_of(Expense).to receive(:save!).and_return(true)
      allow_any_instance_of(Expense).to receive(:expense_date).and_return(nil)

      post expenses_url, params: {
        rental_property_id: property.id,
        expense: { amount: 100.00, category: "repairs", description: "Faucet", expense_date: "", rental_property_id: property.id }
      }, as: :turbo_stream

      expect(response).to have_http_status(:ok)
    end

    it "handles modal-submit validation failure with turbo_stream" do
      expect {
        post expenses_url, params: {
          rental_property_id: property.id,
          expense: { amount: -50.0, category: "repairs", description: "Faucet", expense_date: Date.today, rental_property_id: property.id }
        }, as: :turbo_stream
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("turbo-stream")
      expect(response.body).to include("modal-frame")
    end

    it "should not create expense with other user's property" do
      expect {
        post expenses_url, params: { expense: { amount: 100.0, category: "repairs", expense_date: Date.today, rental_property_id: other_property.id } }
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "should not create expense with other user's reimburse lease" do
      expect {
        post expenses_url, params: { expense: { amount: 100.0, category: "repairs", expense_date: Date.today, rental_property_id: property.id, reimburse_lease_id: other_lease.id } }
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "fails validation and returns errors when custom reimburse amount is invalid" do
      expect {
        post expenses_url, params: {
          expense: {
            amount: 100.0,
            category: "repairs",
            expense_date: Date.today,
            rental_property_id: property.id,
            tenant_reimbursable: "1",
            reimburse_lease_id: lease.id,
            reimburse_amount: -50.0
          }
        }, as: :json
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_content)
      response_json = JSON.parse(response.body)
      expect(response_json.keys).to include("reimburse_amount")
    end
  end

  describe "GET /show" do
    it "renders a successful response" do
      get expense_url(expense)
      expect(response).to be_successful
    end
  end

  describe "GET /edit" do
    it "renders a successful response" do
      get edit_expense_url(expense)
      expect(response).to be_successful
    end
  end

  describe "PATCH /update" do
    it "updates the expense and redirects" do
      patch expense_url(expense), params: { expense: { amount: 200.0 } }
      expect(response).to redirect_to(expense_url(expense))
      expect(expense.reload.amount).to eq(200.0)
    end

    it "updates the expense with reimburse_lease_id" do
      patch expense_url(expense), params: { expense: { reimburse_lease_id: lease.id } }
      expect(response).to redirect_to(expense_url(expense))
    end

    it "should not update expense to other user's property" do
      patch expense_url(expense), params: { expense: { rental_property_id: other_property.id } }
      expect(response).to have_http_status(:not_found)
    end

    it "renders edit on validation failure" do
      patch expense_url(expense), params: { expense: { amount: -50.0 } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /destroy" do
    it "destroys the expense and redirects" do
      expect {
        delete expense_url(expense)
      }.to change(Expense, :count).by(-1)

      expect(response).to redirect_to(expenses_url)
    end
  end
end
