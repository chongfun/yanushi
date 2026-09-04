require "rails_helper"

RSpec.describe "SecurityDepositTransactions", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

  before do
    post session_path, params: { email: user.email, password: "password" }
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe "GET /security_deposit_transactions/:id" do
    it "renders the transaction show view" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      txn = res.value!.data[:transaction]

      get security_deposit_transaction_path(txn)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Deposit Received")
      expect(response.body).to include("$1,000.00")
    end
  end

  describe "GET /security_deposit_transactions/:id/correction" do
    it "renders the correction form for active transaction" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      txn = res.value!.data[:transaction]

      get correction_security_deposit_transaction_path(txn)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Correct deposit received")
    end

    it "redirects with alert if transaction is already voided" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      txn = res.value!.data[:transaction]
      SecurityDepositTransactions::VoidService.call(transaction: txn)

      get correction_security_deposit_transaction_path(txn)
      expect(response).to redirect_to(security_deposit_transaction_path(txn))
      expect(flash[:alert]).to be_present
    end

    it "redirects with alert if transaction is already superseded" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      txn = res.value!.data[:transaction]
      SecurityDepositTransactions::CorrectService.call(transaction: txn, amount_cents: 120_000)

      get correction_security_deposit_transaction_path(txn)
      expect(response).to redirect_to(security_deposit_transaction_path(txn))
      expect(flash[:alert]).to be_present
    end
  end

  describe "POST /security_deposit_transactions/:id/correct" do
    it "corrects transaction and redirects to replacement show page" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      txn = res.value!.data[:transaction]

      post correct_security_deposit_transaction_path(txn), params: {
        security_deposit_transaction: {
          amount: "1500.00",
          occurred_on: Date.current,
          party_id: party.id
        }
      }

      expect(txn.reload).to be_superseded
      replacement = txn.superseded_by
      expect(response).to redirect_to(security_deposit_transaction_path(replacement))
      expect(replacement.amount_cents).to eq(150_000)
    end

    it "renders correction with unprocessable_entity on invalid input" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      txn = res.value!.data[:transaction]

      post correct_security_deposit_transaction_path(txn), params: {
        security_deposit_transaction: {
          amount: "-500",
          occurred_on: Date.current,
          party_id: party.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Correct deposit received")
    end

    it "renders correction with unprocessable_entity when submitting nonexistent charge_id" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )

      charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.current,
        due_on: Date.current
      ).value!.data[:charge]

      app_txn = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.current
      ).value!.data[:transaction]

      post correct_security_deposit_transaction_path(app_txn), params: {
        security_deposit_transaction: {
          amount: "500.00",
          occurred_on: Date.current,
          charge_id: 999_999
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(flash[:alert]).to include("Charge not found")
    end
  end

  describe "POST /security_deposit_transactions/:id/void" do
    it "voids transaction and redirects to deposit dashboard" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      txn = res.value!.data[:transaction]

      post void_security_deposit_transaction_path(txn), params: { reason: "Mistake" }
      expect(response).to redirect_to(tenancy_security_deposit_path(tenancy))
      expect(txn.reload).to be_voided
    end

    it "redirects to transaction path with alert on void failure" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      txn = res.value!.data[:transaction]

      SecurityDepositTransactions::RefundService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 2)
      )

      # Attempting to void the receipt fails due to timeline constraint
      post void_security_deposit_transaction_path(txn)
      expect(response).to redirect_to(security_deposit_transaction_path(txn))
      expect(flash[:alert]).to be_present
    end
  end
end
