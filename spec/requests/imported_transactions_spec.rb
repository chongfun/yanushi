require "rails_helper"

RSpec.describe "ImportedTransactions", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party) { create(:party, user: user, display_name: "Jane Doe") }
  let!(:tenancy) do
    t = create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
    create(:tenancy_party, tenancy: t, party: party, role: "tenant")
    t
  end
  let(:source_document) { create(:source_document, user: user, status: "success") }

  before do
    sign_in_as(user)
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe "GET /imported_transactions" do
    it "renders the list of reviewable and confirmed transactions" do
      create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy)

      get imported_transactions_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Transaction Ingestion")
      expect(response.body).to include("Jane Doe")
    end
  end

  describe "GET /imported_transactions/:id" do
    it "renders the review page" do
      txn = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy)

      get imported_transaction_path(txn)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Review Imported Transaction")
    end
  end

  describe "PATCH /imported_transactions/:id" do
    it "updates transaction details" do
      txn = create(:imported_transaction, user: user, source_document: source_document, status: "unmatched")

      patch imported_transaction_path(txn), params: {
        imported_transaction: {
          matched_party_id: party.id,
          matched_tenancy_id: tenancy.id,
          transaction_kind: "tenant_receipt",
          amount: "1200.00",
          occurred_on: "2026-03-24",
          payment_method: "zelle"
        }
      }

      expect(response).to redirect_to(imported_transaction_path(txn))
      txn.reload
      expect(txn.matched_party).to eq(party)
      expect(txn.matched_tenancy).to eq(tenancy)
      expect(txn.amount_cents).to eq(120_000)
      expect(txn.status).to eq("matched")
    end

    it "renders show with unprocessable_content on invalid update" do
      confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)

      patch imported_transaction_path(confirmed_txn), params: {
        imported_transaction: {
          amount: "999.00"
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns not found when attempting to assign a foreign user's party or tenancy" do
      other_party = create(:party, user: other_user)
      txn = create(:imported_transaction, user: user, source_document: source_document)

      patch imported_transaction_path(txn), params: {
        imported_transaction: {
          matched_party_id: other_party.id
        }
      }

      expect(response).to have_http_status(:not_found)
    end

    it "handles duplicate external identity collision gracefully with 422 instead of 500" do
      candidate_a = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        source: "pdf_upload",
        payment_method: "zelle",
        external_reference: "REF_EXISTS_123"
      )

      candidate_b = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        source: "pdf_upload",
        payment_method: "zelle",
        external_reference: "REF_DIFFERENT_456"
      )

      patch imported_transaction_path(candidate_b), params: {
        imported_transaction: {
          payment_method: "zelle",
          external_reference: "REF_EXISTS_123"
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("already been imported")
      expect(candidate_b.reload.external_reference).to eq("REF_DIFFERENT_456")
    end
  end

  describe "POST /imported_transactions/:id/confirm" do
    it "confirms a tenant_receipt transaction and redirects" do
      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 120_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle"
      )

      post confirm_imported_transaction_path(txn), params: { create_alias: "1" }

      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("Transaction confirmed and recorded successfully.")

      txn.reload
      expect(txn.status).to eq("confirmed")
      expect(txn.confirmed_source).to be_a(Receipt)
    end

    it "redirects with alert on confirmation failure" do
      unclassified_txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "unknown",
        status: "matched"
      )

      post confirm_imported_transaction_path(unclassified_txn)

      expect(response).to redirect_to(imported_transaction_path(unclassified_txn))
      follow_redirect!
      expect(response.body).to include("Transaction requires classification before confirmation")
    end

    it "redirects with alert on unexpected error" do
      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 120_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle"
      )

      allow(ImportedTransactions::ConfirmService).to receive(:call).and_raise(StandardError, "Database failure")

      post confirm_imported_transaction_path(txn)

      expect(response).to redirect_to(imported_transaction_path(txn))
      follow_redirect!
      expect(response.body).to include("Failed to confirm transaction: An unexpected error occurred.")
    end
  end

  describe "DELETE /imported_transactions/:id" do
    it "deletes an unconfirmed transaction" do
      txn = create(:imported_transaction, user: user, source_document: source_document, status: "pending")

      delete imported_transaction_path(txn)
      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("Imported transaction was deleted.")
    end

    it "redirects with alert when trying to delete a confirmed transaction" do
      confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)

      delete imported_transaction_path(confirmed_txn)
      expect(response).to redirect_to(imported_transaction_path(confirmed_txn))
      follow_redirect!
      expect(response.body).to include("Cannot delete a confirmed imported transaction")
    end
  end
end
