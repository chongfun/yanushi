require "rails_helper"

RSpec.describe "SecurityDeposits", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }

  before do
    post session_path, params: { email: user.email, password: "password" }
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe "GET /tenancies/:tenancy_id/security_deposit/new" do
    it "renders the new form" do
      get new_tenancy_security_deposit_path(tenancy)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Set Up Security Deposit")
    end

    it "redirects to show if deposit requirement already exists" do
      create(:security_deposit, tenancy: tenancy)
      get new_tenancy_security_deposit_path(tenancy)
      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
    end
  end

  describe "POST /tenancies/:tenancy_id/security_deposit" do
    it "creates security deposit requirement" do
      expect {
        post tenancy_security_deposit_path(tenancy), params: {
          security_deposit: { required_amount: "2000.00", due_on: Date.current }
        }
      }.to change(SecurityDeposit, :count).by(1)

      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      deposit = tenancy.reload.security_deposit
      expect(deposit.required_amount_cents).to eq(200_000)
    end

    it "renders new with errors on invalid input" do
      post tenancy_security_deposit_path(tenancy), params: {
        security_deposit: { required_amount: "-100", due_on: Date.current }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Set Up Security Deposit")
    end
  end

  describe "GET /tenancies/:tenancy_id/security_deposit" do
    it "renders the security deposit dashboard" do
      create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      get tenancy_security_deposit_path(tenancy)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Security Deposit")
      expect(response.body).to include("Record Deposit Payment")
    end

    it "redirects to new if no deposit exists yet" do
      get tenancy_security_deposit_path(tenancy)
      expect(response).to redirect_to(new_tenancy_security_deposit_path(tenancy))
    end
  end

  describe "GET /tenancies/:tenancy_id/security_deposit/edit" do
    it "renders the edit form before transactions exist" do
      create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      get edit_tenancy_security_deposit_path(tenancy)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Edit Security Deposit Requirement")
    end

    it "redirects with alert if transactions already exist" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      get edit_tenancy_security_deposit_path(tenancy)
      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      expect(flash[:alert]).to be_present
    end
  end

  describe "PATCH /tenancies/:tenancy_id/security_deposit" do
    it "updates the requirement" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      patch tenancy_security_deposit_path(tenancy), params: {
        security_deposit: { required_amount: "2500.00", due_on: Date.current }
      }
      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      expect(deposit.reload.required_amount_cents).to eq(250_000)
    end

    it "renders edit with error on invalid input" do
      create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      patch tenancy_security_deposit_path(tenancy), params: {
        security_deposit: { required_amount: "-500", due_on: Date.current }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Edit Security Deposit Requirement")
    end
  end

  describe "POST /tenancies/:tenancy_id/security_deposit/receive" do
    it "records deposit receipt" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)

      expect {
        post receive_tenancy_security_deposit_path(tenancy), params: {
          party_id: party.id,
          amount: "1000.00",
          occurred_on: Date.current,
          memo: "First half"
        }
      }.to change(SecurityDepositTransaction, :count).by(1)

      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      expect(deposit.held_cents).to eq(100_000)
    end

    it "redirects with alert on failure" do
      create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      post receive_tenancy_security_deposit_path(tenancy), params: {
        party_id: party.id,
        amount: "-100",
        occurred_on: Date.current
      }
      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      expect(flash[:alert]).to be_present
    end
  end

  describe "POST /tenancies/:tenancy_id/security_deposit/refund" do
    it "records deposit refund" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )

      post refund_tenancy_security_deposit_path(tenancy), params: {
        party_id: party.id,
        amount: "500.00",
        occurred_on: Date.current
      }

      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      expect(deposit.held_cents).to eq(50_000)
    end

    it "redirects with alert on failure" do
      create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      post refund_tenancy_security_deposit_path(tenancy), params: {
        party_id: party.id,
        amount: "500.00",
        occurred_on: Date.current
      }
      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      expect(flash[:alert]).to be_present
    end
  end

  describe "POST /tenancies/:tenancy_id/security_deposit/apply" do
    it "applies deposit to charge" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.current,
        due_on: Date.current,
        description: "Repairs"
      ).value!.data[:charge]

      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )

      post apply_tenancy_security_deposit_path(tenancy), params: {
        charge_id: charge.id,
        amount: "500.00",
        occurred_on: Date.current
      }

      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      expect(deposit.held_cents).to eq(50_000)
      expect(tenancy.current_balance_cents).to eq(0)
    end

    it "redirects with alert on failure" do
      create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      post apply_tenancy_security_deposit_path(tenancy), params: {
        charge_id: 999_999,
        amount: "500.00",
        occurred_on: Date.current
      }
      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      expect(flash[:alert]).to be_present
    end
  end
end
