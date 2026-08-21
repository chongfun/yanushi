require "rails_helper"

RSpec.describe "SourceDocuments", type: :request do
  let(:user) { create(:user) }

  before do
    sign_in_as(user)
  end

  describe "GET /source_documents/new" do
    it "renders upload form" do
      get new_source_document_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ingest Source Document")
    end
  end

  describe "POST /source_documents" do
    it "uploads document and redirects to imported_transactions_path" do
      pdf_file = fixture_file_upload(
        "receipts/202604 Zelle.pdf",
        "application/pdf"
      )

      post source_documents_path, params: {
        source_document: {
          pdf_file: pdf_file
        }
      }

      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("Document uploaded successfully")
    end

    it "shows informative notice when re-uploading an already processing document" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      create(:source_document, user: user, attachment_file: pdf_file.read, status: "processing")
      pdf_file.rewind

      post source_documents_path, params: { source_document: { pdf_file: pdf_file } }

      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("This document is already currently being processed in the background.")
    end

    it "shows informative notice when re-uploading an already processed document" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      create(:source_document, user: user, attachment_file: pdf_file.read, status: "success")
      pdf_file.rewind

      post source_documents_path, params: { source_document: { pdf_file: pdf_file } }

      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("This document has already been processed successfully.")
    end

    it "shows informative alert when re-uploading a failed document, prompting Retry" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      create(:source_document, user: user, attachment_file: pdf_file.read, status: "failed", error_message: "Format error")
      pdf_file.rewind

      post source_documents_path, params: { source_document: { pdf_file: pdf_file } }

      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("This document previously failed processing. Please click Retry in the Recent Uploads list.")
    end

    it "redirects to new on upload failure" do
      post source_documents_path, params: {
        source_document: {
          pdf_file: nil
        }
      }

      expect(response).to redirect_to(new_source_document_path)
      follow_redirect!
      expect(response.body).to include("Please select a PDF file to upload.")
    end
  end

  describe "GET /source_documents/:id/download" do
    it "sends document attachment inline" do
      doc = create(:source_document, user: user, attachment_file: "test bytes", attachment_filename: "doc.pdf", attachment_content_type: "application/pdf")

      get download_source_document_path(doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("test bytes")
      expect(response.content_type).to eq("application/pdf")
    end

    it "redirects with alert if attachment is missing" do
      doc = create(:source_document, user: user)
      doc.update_column(:attachment_file, nil)

      get download_source_document_path(doc)
      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("Document attachment data is missing.")
    end
  end

  describe "DELETE /source_documents/:id" do
    it "deletes document and redirects" do
      doc = create(:source_document, user: user)

      delete source_document_path(doc)
      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("Upload record was removed.")
    end

    it "redirects with alert if deletion fails due to confirmed transactions" do
      doc = create(:source_document, user: user)
      create(:imported_transaction, :confirmed_receipt, user: user, source_document: doc)

      delete source_document_path(doc)
      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("Cannot delete document with confirmed transactions")
    end
  end

  describe "POST /source_documents/:id/retry" do
    it "retries a failed document and redirects with notice" do
      doc = create(:source_document, user: user, status: "failed", error_message: "Old error")

      expect {
        post retry_source_document_path(doc)
      }.to have_enqueued_job(IngestSourceDocumentJob).with(doc.id)

      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("Document processing has been re-queued in the background.")
      expect(doc.reload.status).to eq("processing")
    end

    it "redirects with alert if retry fails" do
      doc = create(:source_document, user: user, status: "success")

      post retry_source_document_path(doc)
      expect(response).to redirect_to(imported_transactions_path)
      follow_redirect!
      expect(response.body).to include("Document has already been processed successfully.")
    end
  end
end
