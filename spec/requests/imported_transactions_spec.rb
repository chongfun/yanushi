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

  describe "GET /inbox and GET /imported_transactions" do
    it "renders the review queue view by default" do
      txn = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy)

      get inbox_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Inbox")
      expect(response.body).to include("Needs review")
      expect(response.body).to include("Jane Doe")
    end

    it "renders processing and failed documents view when requested" do
      failed_doc = create(:source_document, user: user, status: "failed", error_message: "Corrupted PDF file")
      proc_doc = create(:source_document, user: user, status: "processing")

      get inbox_path(view: "processing")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Processing &amp; failed")
      expect(response.body).to include("Corrupted PDF file")
      expect(response.body).to include("Processing…")
    end

    it "renders paginated and filtered history view when requested" do
      txn_zelle = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document, matched_tenancy: tenancy, payment_method: "zelle")
      _txn_other = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document, matched_tenancy: tenancy, payment_method: "check")

      get inbox_path(view: "history", payment_method: "zelle")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("History")
      expect(response.body).to include("Receipt — #{property.address}")
    end

    it "does not query confirmed history records when rendering review view" do
      expect(ImportedTransactions::HistoryQuery).not_to receive(:new)

      get inbox_path(view: "review")
      expect(response).to have_http_status(:ok)
    end

    it "does not instantiate InboxQuery or materialize reviewable transactions when rendering history view" do
      expect(ImportedTransactions::InboxQuery).not_to receive(:new)

      get inbox_path(view: "history")
      expect(response).to have_http_status(:ok)
    end

    it "does not instantiate InboxQuery or materialize reviewable transactions when rendering processing view" do
      expect(ImportedTransactions::InboxQuery).not_to receive(:new)

      get inbox_path(view: "processing")
      expect(response).to have_http_status(:ok)
    end

    it "enforces user isolation across views" do
      other_doc = create(:source_document, user: other_user, status: "failed", error_message: "Other secret doc")
      other_txn = create(:imported_transaction, :matched, user: other_user, payer_name: "Secret Foreign Payer")

      get inbox_path(view: "review")
      expect(response.body).not_to include("Secret Foreign Payer")

      get inbox_path(view: "processing")
      expect(response.body).not_to include("Other secret doc")
    end

    it "supports selected_id query param to choose the active review item" do
      txn1 = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000)
      txn2 = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy, amount_cents: 200_000)

      get inbox_path(selected_id: txn1.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="review_form_#{txn1.id}"))

      get inbox_path(selected_id: 999_999)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="review_form_#{txn2.id}"))
    end
  end

  describe "GET /imported_transactions/:id" do
    it "renders the standalone review page with queue item position for non-frame requests" do
      txn1 = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy)
      _txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)

      get imported_transaction_path(txn1)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Item 2 of 2 needing review")
      expect(response.body).to include("Back to Inbox")
      expect(response.body).to include("Save without confirming")
    end

    it "renders review_detail partial within inbox_review frame with revision tag for turbo frame requests" do
      txn1 = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy)

      get imported_transaction_path(txn1), headers: { "Turbo-Frame" => "inbox_review" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(<turbo-frame id="inbox_review">))
      expect(response.body).to include(%(data-controller="inbox-sync"))
      expect(response.body).to include(%(data-inbox-sync-revision-value="#{user.inbox_revision}"))
      expect(response.body).to include(%(id="review_form_#{txn1.id}"))
      expect(response.body).not_to include("<!DOCTYPE html>")
    end

    it "renders next canonical transaction when requested transaction is deleted concurrently during frame request" do
      txn1 = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy)
      txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)

      original_inbox_query = ImportedTransactions::InboxQuery.method(:new)
      allow(ImportedTransactions::InboxQuery).to receive(:new) do |**args|
        if args[:updated_transaction_id] == txn1.id
          txn1.destroy!
          user.increment_inbox_revision!
        end
        original_inbox_query.call(**args)
      end

      get imported_transaction_path(txn1), headers: { "Turbo-Frame" => "inbox_review" }
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(%(id="review_form_#{txn1.id}"))
      expect(response.body).to include(%(id="review_form_#{txn2.id}"))
      expect(response.body).to include(%(data-inbox-sync-revision-value="#{user.reload.inbox_revision}"))
    end

    it "redirects to next transaction when requested transaction is deleted concurrently during HTML request" do
      txn1 = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy)
      txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)

      original_inbox_query = ImportedTransactions::InboxQuery.method(:new)
      allow(ImportedTransactions::InboxQuery).to receive(:new) do |**args|
        if args[:updated_transaction_id] == txn1.id
          txn1.destroy!
          user.increment_inbox_revision!
        end
        original_inbox_query.call(**args)
      end

      get imported_transaction_path(txn1)
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(imported_transaction_path(txn2))
    end

    it "renders next canonical transaction when requested transaction is confirmed concurrently during frame request" do
      txn1 = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy)
      txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)
      receipt = create(:receipt, user: user, tenancy: tenancy, amount_cents: txn1.amount_cents)

      original_inbox_query = ImportedTransactions::InboxQuery.method(:new)
      allow(ImportedTransactions::InboxQuery).to receive(:new) do |**args|
        if args[:updated_transaction_id] == txn1.id
          txn1.update_columns(status: "confirmed", confirmed_source_type: "Receipt", confirmed_source_id: receipt.id)
          user.increment_inbox_revision!
        end
        original_inbox_query.call(**args)
      end

      get imported_transaction_path(txn1), headers: { "Turbo-Frame" => "inbox_review" }
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(%(id="review_form_#{txn1.id}"))
      expect(response.body).to include(%(id="review_form_#{txn2.id}"))
      expect(response.body).to include(%(data-inbox-sync-revision-value="#{user.reload.inbox_revision}"))
    end

    it "redirects to next transaction when requested transaction is confirmed concurrently during HTML request" do
      txn1 = create(:imported_transaction, :matched, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy)
      txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)
      receipt = create(:receipt, user: user, tenancy: tenancy, amount_cents: txn1.amount_cents)

      original_inbox_query = ImportedTransactions::InboxQuery.method(:new)
      allow(ImportedTransactions::InboxQuery).to receive(:new) do |**args|
        if args[:updated_transaction_id] == txn1.id
          txn1.update_columns(status: "confirmed", confirmed_source_type: "Receipt", confirmed_source_id: receipt.id)
          user.increment_inbox_revision!
        end
        original_inbox_query.call(**args)
      end

      get imported_transaction_path(txn1)
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(imported_transaction_path(txn2))
    end

    it "renders next canonical transaction when requested transaction ID is already deleted in frame request" do
      txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)

      get imported_transaction_path(999_999), headers: { "Turbo-Frame" => "inbox_review" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="review_form_#{txn2.id}"))
      expect(response.body).to include(%(data-inbox-sync-revision-value="#{user.inbox_revision}"))
    end

    it "redirects to next transaction when requested transaction ID is already deleted in HTML request" do
      txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)

      get imported_transaction_path(999_999)
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(imported_transaction_path(txn2))
    end

    it "renders accurate Item X of Y position using SQL counting with deterministic order" do
      t1 = create(:imported_transaction, :unmatched, user: user, source_document: source_document, created_at: 3.hours.ago)
      t2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document, created_at: 2.hours.ago)
      t3 = create(:imported_transaction, :unmatched, user: user, source_document: source_document, created_at: 1.hour.ago)

      get imported_transaction_path(t2)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Item 2 of 3")
    end
  end

  describe "POST /imported_transactions/:id/confirm" do
    let!(:txn1) do
      create(
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
    end

    context "standalone workflow (HTML format)" do
      it "confirms and redirects to the next reviewable transaction" do
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)

        post confirm_imported_transaction_path(txn1, format: :html), params: { create_alias: "1" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(imported_transaction_path(txn2))

        txn1.reload
        expect(txn1.status).to eq("confirmed")
        expect(txn1.confirmed_source).to be_a(Receipt)
      end

      it "confirms and redirects to /inbox when no items remain" do
        post confirm_imported_transaction_path(txn1, format: :html), params: { create_alias: "1" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(inbox_path)

        txn1.reload
        expect(txn1.status).to eq("confirmed")
      end

      it "renders show with 422 and preserves form on validation error" do
        unclassified_txn = create(:imported_transaction, user: user, source_document: source_document, transaction_kind: "unknown", status: "matched")

        post confirm_imported_transaction_path(unclassified_txn, format: :html)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Transaction requires classification before confirmation")
      end

      it "confirms an initially unknown transaction directly in one pass with submitted parameters in standalone HTML workflow" do
        unclassified_txn = create(
          :imported_transaction,
          :unmatched,
          user: user,
          source_document: source_document,
          transaction_kind: "unknown",
          amount_cents: 150_000,
          occurred_on: Date.new(2026, 3, 24),
          payment_method: "zelle"
        )
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)

        # GET show page to check button is server-enabled for progressive enhancement
        get imported_transaction_path(unclassified_txn)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(id="confirm_btn_#{unclassified_txn.id}"))
        expect(response.body).not_to include(%(id="confirm_btn_#{unclassified_txn.id}" disabled))

        # POST confirm directly with submitted classification in one pass
        post confirm_imported_transaction_path(unclassified_txn, format: :html), params: {
          imported_transaction: {
            transaction_kind: "tenant_receipt",
            matched_party_id: party.id,
            matched_tenancy_id: tenancy.id,
            lock_version: unclassified_txn.lock_version
          }
        }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(imported_transaction_path(txn2))

        unclassified_txn.reload
        expect(unclassified_txn.status).to eq("confirmed")
        expect(unclassified_txn.transaction_kind).to eq("tenant_receipt")
        expect(unclassified_txn.confirmed_source).to be_a(Receipt)
      end

      it "redirects to next transaction when transaction is deleted before lock acquisition" do
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)
        allow(ImportedTransactions::ConfirmService).to receive(:call).and_wrap_original do |original, **kwargs|
          txn1.destroy!
          user.increment_inbox_revision!
          original.call(**kwargs)
        end

        post confirm_imported_transaction_path(txn1, format: :html)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(imported_transaction_path(txn2))
        expect(flash[:notice]).to eq("The transaction was deleted in another session.")
      end
    end

    context "inbox frame workflow (Turbo Stream format)" do
      it "renders next transaction with inbox_sync revision and gone toast when transaction is deleted before lock acquisition" do
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)
        allow(ImportedTransactions::ConfirmService).to receive(:call).and_wrap_original do |original, **kwargs|
          txn1.destroy!
          user.increment_inbox_revision!
          original.call(**kwargs)
        end

        post confirm_imported_transaction_path(txn1), as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review_queue_list">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review">))
        expect(response.body).to include(%(id="review_form_#{txn2.id}"))
        expect(response.body).to include(%(data-inbox-sync-revision-value="#{user.reload.inbox_revision}"))
        expect(response.body).to include("The transaction was deleted in another session.")
        expect(response.body).not_to include("Transaction confirmed and recorded successfully.")
      end

      it "confirms and emits Turbo Streams updating queue row, badges, tab counts, and next review detail" do
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)

        post confirm_imported_transaction_path(txn1), as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review_queue_list">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="sidebar_inbox_badge">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="drawer_inbox_badge">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="mobile_inbox_badge">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="tab_review_count">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review">))
        expect(response.body).to include(%(<turbo-stream action="append" target="flash-messages">))

        txn1.reload
        expect(txn1.status).to eq("confirmed")
      end

      it "confirms and streams caught-up state when no items remain" do
        post confirm_imported_transaction_path(txn1), as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review_workspace">))
        expect(response.body).to include("You’re caught up")
      end

      it "applies submitted parameters during confirmation" do
        unmatched_txn = create(
          :imported_transaction,
          user: user,
          source_document: source_document,
          transaction_kind: "unknown",
          status: "unmatched",
          amount_cents: 100_000,
          occurred_on: Date.current
        )

        post confirm_imported_transaction_path(unmatched_txn), params: {
          imported_transaction: {
            transaction_kind: "tenant_receipt",
            matched_party_id: party.id,
            matched_tenancy_id: tenancy.id,
            payment_method: "check",
            external_reference: "CHK-101"
          }
        }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        unmatched_txn.reload
        expect(unmatched_txn.status).to eq("confirmed")
        expect(unmatched_txn.transaction_kind).to eq("tenant_receipt")
        expect(unmatched_txn.payment_method).to eq("check")
        expect(unmatched_txn.external_reference).to eq("CHK-101")
        expect(unmatched_txn.confirmed_source).to be_a(Receipt)
      end

      it "renders review form into inbox_review frame with 422 on failure" do
        unclassified_txn = create(:imported_transaction, user: user, source_document: source_document, transaction_kind: "unknown", status: "matched")

        post confirm_imported_transaction_path(unclassified_txn), as: :turbo_stream

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Transaction requires classification before confirmation")
        expect(response.body).to include(%(id="rev-kind-#{unclassified_txn.id}"))
      end
    end
  end

  describe "PATCH /imported_transactions/:id" do
    let(:txn) { create(:imported_transaction, user: user, source_document: source_document, status: "unmatched") }

    context "standalone workflow (HTML format)" do
      it "updates transaction details and redirects to show" do
        patch imported_transaction_path(txn, format: :html), params: {
          imported_transaction: {
            matched_party_id: party.id,
            matched_tenancy_id: tenancy.id,
            transaction_kind: "tenant_receipt",
            amount: "1200.00",
            occurred_on: "2026-03-24",
            payment_method: "zelle"
          }
        }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(imported_transaction_path(txn))
        txn.reload
        expect(txn.matched_party).to eq(party)
        expect(txn.matched_tenancy).to eq(tenancy)
        expect(txn.status).to eq("matched")
      end

      it "renders show with 422 on invalid update" do
        confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)

        patch imported_transaction_path(confirmed_txn, format: :html), params: {
          imported_transaction: { amount: "999.00" }
        }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "redirects to next transaction when transaction is deleted before lock acquisition" do
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)
        allow(ImportedTransactions::UpdateService).to receive(:call).and_wrap_original do |original, **kwargs|
          txn.destroy!
          user.increment_inbox_revision!
          original.call(**kwargs)
        end

        patch imported_transaction_path(txn, format: :html), params: {
          imported_transaction: { amount: "1200.00" }
        }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(imported_transaction_path(txn2))
        expect(flash[:notice]).to eq("The transaction was deleted in another session.")
      end
    end

    context "inbox frame workflow (Turbo Stream format)" do
      it "renders next transaction with inbox_sync revision when transaction is deleted before lock acquisition" do
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)
        allow(ImportedTransactions::UpdateService).to receive(:call).and_wrap_original do |original, **kwargs|
          txn.destroy!
          user.increment_inbox_revision!
          original.call(**kwargs)
        end

        patch imported_transaction_path(txn), params: {
          imported_transaction: { amount: "1200.00" }
        }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review_queue_list">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review">))
        expect(response.body).to include(%(id="review_form_#{txn2.id}"))
        expect(response.body).to include(%(data-inbox-sync-revision-value="#{user.reload.inbox_revision}"))
        expect(response.body).to include("The transaction was deleted in another session.")
        expect(response.body).not_to include("Transaction record updated successfully.")
      end
      it "updates transaction details and streams replacements" do
        patch imported_transaction_path(txn), params: {
          imported_transaction: {
            matched_party_id: party.id,
            matched_tenancy_id: tenancy.id,
            transaction_kind: "tenant_receipt",
            payment_method: "zelle"
          }
        }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include(%(<turbo-stream action="replace" target="imported_transaction_#{txn.id}">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review">))
      end

      it "renders review form with 422 on update error in turbo stream format" do
        confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)

        patch imported_transaction_path(confirmed_txn), params: {
          imported_transaction: { amount: "999.00" }
        }, as: :turbo_stream

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review">))
      end

      it "renders canonical transaction snapshot when another session updates the record before response snapshot" do
        original_call = ImportedTransactions::UpdateService.method(:call)
        allow(ImportedTransactions::UpdateService).to receive(:call) do |user:, transaction:, params:|
          res = original_call.call(user: user, transaction: transaction, params: params)
          transaction.reload.update_columns(amount_cents: 180_000, lock_version: transaction.lock_version + 1)
          user.increment_inbox_revision!
          res
        end

        patch imported_transaction_path(txn), params: {
          imported_transaction: {
            amount: "1200.00",
            lock_version: txn.lock_version
          }
        }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("$1,800.00")
        expect(response.body).to include(%(data-inbox-sync-revision-value="#{user.reload.inbox_revision}"))
      end

      it "transitions cleanly to next transaction when record is deleted before response snapshot" do
        txn2 = create(:imported_transaction, user: user, source_document: source_document, status: "unmatched", amount_cents: 250_000)

        original_call = ImportedTransactions::UpdateService.method(:call)
        allow(ImportedTransactions::UpdateService).to receive(:call) do |user:, transaction:, params:|
          res = original_call.call(user: user, transaction: transaction, params: params)
          transaction.destroy!
          user.increment_inbox_revision!
          res
        end

        patch imported_transaction_path(txn), params: {
          imported_transaction: {
            amount: "1200.00",
            lock_version: txn.lock_version
          }
        }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(%(id="review_form_#{txn.id}"))
        expect(response.body).to include(%(id="review_form_#{txn2.id}"))
        expect(response.body).to include(%(data-inbox-sync-revision-value="#{user.reload.inbox_revision}"))
      end
    end
  end

  describe "DELETE /imported_transactions/:id" do
    let!(:txn1) { create(:imported_transaction, user: user, source_document: source_document, status: "unmatched") }

    context "standalone workflow (HTML format)" do
      it "deletes transaction and redirects to next reviewable transaction" do
        txn2 = create(:imported_transaction, user: user, source_document: source_document, status: "unmatched")

        delete imported_transaction_path(txn1, format: :html)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(imported_transaction_path(txn2))
        expect(ImportedTransaction.exists?(txn1.id)).to be(false)
      end

      it "deletes transaction and redirects to /inbox when no items remain" do
        delete imported_transaction_path(txn1, format: :html)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(inbox_path)
        expect(ImportedTransaction.exists?(txn1.id)).to be(false)
      end

      it "renders show with 422 on delete failure" do
        confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)

        delete imported_transaction_path(confirmed_txn, format: :html)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "renders show with 422 on delete conflict when lock_version is stale" do
        txn1.update!(amount_cents: 250_000)
        expect(txn1.lock_version).to eq(1)

        delete imported_transaction_path(txn1, format: :html), params: {
          lock_version: 0
        }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("This transaction was updated in another session")
        expect(ImportedTransaction.exists?(txn1.id)).to be(true)
      end

      it "redirects to next transaction when transaction is deleted before lock acquisition" do
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)
        allow(ImportedTransactions::DestroyService).to receive(:call).and_wrap_original do |original, **kwargs|
          txn1.destroy!
          user.increment_inbox_revision!
          original.call(**kwargs)
        end

        delete imported_transaction_path(txn1, format: :html)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(imported_transaction_path(txn2))
        expect(flash[:notice]).to eq("The transaction was deleted in another session.")
      end
    end

    context "inbox frame workflow (Turbo Stream format)" do
      it "renders next transaction with inbox_sync revision when transaction is deleted before lock acquisition" do
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)
        allow(ImportedTransactions::DestroyService).to receive(:call).and_wrap_original do |original, **kwargs|
          txn1.destroy!
          user.increment_inbox_revision!
          original.call(**kwargs)
        end

        delete imported_transaction_path(txn1), as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review_queue_list">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review">))
        expect(response.body).to include(%(id="review_form_#{txn2.id}"))
        expect(response.body).to include(%(data-inbox-sync-revision-value="#{user.reload.inbox_revision}"))
        expect(response.body).to include("The transaction was deleted in another session.")
        expect(response.body).not_to include("Imported transaction was deleted.")
      end
      it "deletes transaction and streams queue update and badge updates when next item exists" do
        txn2 = create(:imported_transaction, :unmatched, user: user, source_document: source_document)

        delete imported_transaction_path(txn1), as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review_queue_list">))
        expect(response.body).to include(%(<turbo-stream action="replace" target="sidebar_inbox_badge">))
        expect(ImportedTransaction.exists?(txn1.id)).to be(false)
      end

      it "deletes transaction and streams caught-up workspace when last item is deleted" do
        delete imported_transaction_path(txn1), as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review_workspace">))
        expect(response.body).to include("You’re caught up")
        expect(ImportedTransaction.exists?(txn1.id)).to be(false)
      end

      it "renders review form with 422 on delete error in turbo stream format" do
        confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)

        delete imported_transaction_path(confirmed_txn), as: :turbo_stream
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review">))
      end

      it "renders review form with 422 conflict when lock_version is stale in turbo stream format" do
        txn1.update!(amount_cents: 300_000)
        expect(txn1.lock_version).to eq(1)

        delete imported_transaction_path(txn1), params: {
          imported_transaction: { lock_version: 0 }
        }, as: :turbo_stream

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(%(<turbo-stream action="replace" target="inbox_review">))
        expect(response.body).to include("This transaction was updated in another session")
        expect(ImportedTransaction.exists?(txn1.id)).to be(true)
      end
    end
  end
end
