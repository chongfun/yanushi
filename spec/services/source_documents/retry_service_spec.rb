require "rails_helper"

RSpec.describe SourceDocuments::RetryService do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:source_document) { create(:source_document, user: user, status: "failed", error_message: "Parse error") }

  describe "#call" do
    it "resets a failed document to processing and enqueues IngestSourceDocumentJob" do
      expect {
        result = described_class.call(user: user, document: source_document)
        expect(result).to be_success
        expect(source_document.reload.status).to eq("processing")
        expect(source_document.error_message).to be_nil
      }.to have_enqueued_job(IngestSourceDocumentJob).with(source_document.id)
    end

    it "rejects retrying a document of another user" do
      result = described_class.call(user: other_user, document: source_document)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
      expect(source_document.reload.status).to eq("failed")
    end

    it "rejects retrying an already successful document" do
      source_document.update_columns(status: "success", error_message: nil)

      result = described_class.call(user: user, document: source_document)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:already_processed)
    end

    it "rejects retrying a document with confirmed transactions" do
      source_document.update_columns(status: "success", error_message: nil)
      create(:imported_transaction, :confirmed_receipt, source_document: source_document, user: user)

      result = described_class.call(user: user, document: source_document)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:immutable)
    end

    it "handles enqueue failure by updating document to failed with error" do
      allow(IngestSourceDocumentJob).to receive(:perform_later).and_raise(StandardError, "Queue timeout")

      result = described_class.call(user: user, document: source_document)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:enqueue_failed)
      expect(source_document.reload.status).to eq("failed")
      expect(source_document.error_message).to include("Queue timeout")
    end
  end
end
