require "rails_helper"

RSpec.describe "PaymentIngestions", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user, display_name: "Jane Doe") }
  let(:document) do
    create(:payment_document,
      user: user,
      attachment_file: "dummy_pdf_content",
      attachment_filename: "receipt.pdf",
      attachment_content_type: "application/pdf",
      status: :success
    )
  end
  let!(:ingestion) do
    create(:payment_ingestion,
      user: user,
      source: "pdf_upload",
      status: "matched",
      payer_name: "Jane Doe",
      amount: 1300.0,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "TXNTEST123",
      party: party,
      tenancy: tenancy,
      payment_document: document
    )
  end

  before do
    sign_in_as(user)
  end

  describe "GET /payment_ingestions" do
    it "renders a successful response" do
      get payment_ingestions_url
      expect(response).to be_successful
      expect(response.body).to include("Payment Ingestion")
    end
  end

  describe "GET /payment_ingestions/new" do
    it "renders a successful response" do
      get new_payment_ingestion_url
      expect(response).to be_successful
    end
  end

  describe "POST /payment_ingestions" do
    it "creates payment ingestion" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")

      expect {
        perform_enqueued_jobs do
          post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
        end
      }.to change(PaymentIngestion, :count).by(1)

      expect(response).to redirect_to(payment_ingestions_url)
      expect(flash[:notice]).to eq("Document uploaded successfully and is being processed in the background.")
    end

    it "should not create duplicate payment ingestion and should show friendly message" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")

      perform_enqueued_jobs do
        post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
      end

      expect {
        perform_enqueued_jobs do
          post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
        end
      }.not_to change(PaymentIngestion, :count)

      expect(response).to redirect_to(payment_ingestions_url)
      failed_doc = PaymentDocument.last
      expect(failed_doc.status).to eq("failed")
      expect(failed_doc.error_message).to match(/This payment receipt has already been uploaded/)
    end

    it "should create multiple payment ingestions when uploading a bank statement" do
      alice = create(:party, user: user, display_name: "Alice Smith")
      u1 = create(:rentable_unit, property: property, name: "Unit 1")
      l1 = create(:tenancy, rentable_unit: u1, agreement_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), termination_date: nil)
      create(:tenancy_party, tenancy: l1, party: alice, role: "tenant", effective_from: Date.new(2023, 1, 1))

      pdf_file = fixture_file_upload("statements/20260416-statements-1234-.pdf", "application/pdf")

      expect {
        perform_enqueued_jobs do
          post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
        end
      }.to change(PaymentIngestion, :count).by(1)

      expect(response).to redirect_to(payment_ingestions_url)
      expect(PaymentDocument.last.status).to eq("success")
    end

    it "should return error if statement uploaded but no matching tenants found" do
      pdf_file = fixture_file_upload("statements/20260416-statements-1234-.pdf", "application/pdf")

      expect {
        perform_enqueued_jobs do
          post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
        end
      }.not_to change(PaymentIngestion, :count)

      expect(response).to redirect_to(payment_ingestions_url)
      failed_doc = PaymentDocument.last
      expect(failed_doc.status).to eq("failed")
      expect(failed_doc.error_message).to match(/No matching tenant transactions found/)
    end

    it "should reject uploads with invalid content type" do
      text_file = Rack::Test::UploadedFile.new(
        StringIO.new("This is just a plain text file, not a PDF."),
        "application/pdf",
        false,
        original_filename: "not_a_pdf.pdf"
      )

      expect {
        post payment_ingestions_url, params: { payment_ingestion: { pdf_file: text_file } }
      }.not_to change(PaymentDocument, :count)

      expect(response).to redirect_to(new_payment_ingestion_url)
      expect(flash[:alert]).to eq("Only PDF files are supported.")
    end

    it "should reject uploads that exceed file size limit" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")

      allow_any_instance_of(ActionDispatch::Http::UploadedFile).to receive(:size).and_return(11.megabytes)

      expect {
        post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
      }.not_to change(PaymentDocument, :count)

      expect(response).to redirect_to(new_payment_ingestion_url)
      expect(flash[:alert]).to eq("File size exceeds the 10MB limit.")
    end

    it "rejects upload when pdf_file parameter is missing" do
      post payment_ingestions_url, params: { payment_ingestion: { pdf_file: nil } }
      expect(response).to redirect_to(new_payment_ingestion_url)
      expect(flash[:alert]).to eq("Please select a PDF file to upload.")
    end

    it "handles ActiveRecord::RecordInvalid during upload" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      invalid_doc = PaymentDocument.new
      invalid_doc.errors.add(:base, "Invalid PDF content")
      allow_any_instance_of(User).to receive_message_chain(:payment_documents, :create!).and_raise(ActiveRecord::RecordInvalid.new(invalid_doc))

      post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
      expect(response).to redirect_to(new_payment_ingestion_path)
      expect(flash[:alert]).to include("Upload failed: Invalid PDF content")
    end

    it "handles unexpected error during upload" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      allow_any_instance_of(User).to receive_message_chain(:payment_documents, :create!).and_raise(StandardError.new("unexpected issue"))

      post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
      expect(response).to redirect_to(new_payment_ingestion_path)
      expect(flash[:alert]).to include("Upload failed: An unexpected error occurred")
    end
  end

  describe "GET /payment_ingestions/:id" do
    it "renders a successful response" do
      get payment_ingestion_url(ingestion)
      expect(response).to be_successful
    end

    it "renders a successful response for a confirmed ingestion with party display name" do
      post confirm_payment_ingestion_url(ingestion), params: { create_alias: "0" }
      expect(ingestion.reload.status).to eq("confirmed")

      get payment_ingestion_url(ingestion)
      expect(response).to be_successful
      expect(response.body).to include(party.display_name)
      expect(response.body).to include("Transaction Confirmed!")
    end
  end

  describe "PATCH /payment_ingestions/:id" do
    it "updates payment ingestion" do
      patch payment_ingestion_url(ingestion), params: {
        payment_ingestion: {
          amount: 1400.0,
          payment_method: "venmo"
        }
      }
      expect(response).to redirect_to(payment_ingestion_url(ingestion))
      expect(ingestion.reload.amount).to eq(1400.0)
      expect(ingestion.payment_method).to eq("venmo")
    end

    it "should not update payment ingestion with another user's party" do
      other_user = create(:user)
      other_party = create(:party, user: other_user)

      patch payment_ingestion_url(ingestion), params: {
        payment_ingestion: {
          party_id: other_party.id
        }
      }

      expect(response).to have_http_status(:not_found)
      expect(ingestion.reload.party).to eq(party)
    end

    it "should not update payment ingestion with another user's tenancy" do
      other_user = create(:user)
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)

      patch payment_ingestion_url(ingestion), params: {
        payment_ingestion: {
          tenancy_id: other_tenancy.id
        }
      }

      expect(response).to have_http_status(:not_found)
      expect(ingestion.reload.tenancy).to eq(tenancy)
    end

    it "renders show with unprocessable_entity on validation failure" do
      patch payment_ingestion_url(ingestion), params: {
        payment_ingestion: {
          transaction_number: "invalid@char"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "automatically changes status to matched when updating an unmatched ingestion to be confirmable" do
      unmatched_ingestion = create(:payment_ingestion, user: user, status: :unmatched, party: nil, tenancy: nil)
      patch payment_ingestion_url(unmatched_ingestion), params: {
        payment_ingestion: {
          party_id: party.id,
          tenancy_id: tenancy.id,
          amount: 100.0,
          payment_date: Date.today,
          payment_method: "zelle"
        }
      }
      expect(response).to redirect_to(payment_ingestion_url(unmatched_ingestion))
      expect(unmatched_ingestion.reload.status).to eq("matched")
    end

    it "allows blank party_id and tenancy_id to cover else branches of checking their presence" do
      patch payment_ingestion_url(ingestion), params: {
        payment_ingestion: {
          party_id: "",
          tenancy_id: ""
        }
      }
      expect(response).to redirect_to(payment_ingestion_url(ingestion))
    end
  end

  describe "GET /payment_ingestions/:id/download" do
    it "downloads payment attachment" do
      get download_payment_ingestion_url(ingestion)
      expect(response).to be_successful
      expect(response.body).to eq("dummy_pdf_content")
    end

    it "redirects with alert when downloading receipt attachment and payment document is missing" do
      ingestion_without_doc = create(:payment_ingestion, user: user, payment_document: nil)
      get download_payment_ingestion_url(ingestion_without_doc)
      expect(response).to redirect_to(payment_ingestion_path(ingestion_without_doc))
      expect(flash[:alert]).to eq("Receipt attachment data is missing.")
    end
  end

  describe "POST /payment_ingestions/:id/confirm" do
    it "confirms payment ingestion" do
      expect {
        post confirm_payment_ingestion_url(ingestion), params: { create_alias: "0" }
      }.to change(TenantPayment, :count).by(1)

      expect(response).to redirect_to(payment_ingestions_url)
      expect(ingestion.reload.status).to eq("confirmed")
    end

    it "handles ConfirmationError during confirm" do
      allow(PaymentIngestions::ConfirmService).to receive(:call).and_return(
        ServiceResult.failure(error: "custom confirmation error", code: :confirmation_error)
      )
      post confirm_payment_ingestion_url(ingestion)
      expect(response).to redirect_to(payment_ingestion_path(ingestion))
      expect(flash[:alert]).to eq("custom confirmation error")
    end

    it "handles unexpected error during confirm" do
      allow(PaymentIngestions::ConfirmService).to receive(:call).and_raise(StandardError.new("something went wrong"))
      post confirm_payment_ingestion_url(ingestion)
      expect(response).to redirect_to(payment_ingestion_path(ingestion))
      expect(flash[:alert]).to include("Failed to confirm payment: An unexpected error occurred")
    end
  end

  describe "DELETE /payment_ingestions/:id" do
    it "destroys payment ingestion" do
      expect {
        delete payment_ingestion_url(ingestion)
      }.to change(PaymentIngestion, :count).by(-1)

      expect(response).to redirect_to(payment_ingestions_url)
    end
  end

  describe "pagination" do
    it "paginates confirmed ingestions on index page" do
      22.times do |i|
        create(:payment_ingestion,
          user: user,
          source: "pdf_upload",
          status: "confirmed",
          payer_name: "Jane Doe #{i}",
          amount: 100.0,
          payment_date: Date.current,
          payment_method: "zelle",
          transaction_number: "TXNPAG#{i}",
          payment_document: document
        )
      end

      get payment_ingestions_url
      expect(response).to be_successful
    end
  end
end
