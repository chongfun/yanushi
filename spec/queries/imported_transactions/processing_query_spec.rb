require "rails_helper"

RSpec.describe ImportedTransactions::ProcessingQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:query) { described_class.new(user: user) }

  describe "#call" do
    it "returns processing and failed documents with revision and common counts" do
      proc_doc1 = create(:source_document, user: user, status: "processing", attachment_filename: "doc1.pdf")
      proc_doc2 = create(:source_document, user: user, status: "processing", attachment_filename: "doc2.pdf")
      fail_doc = create(:source_document, user: user, status: "failed", error_message: "Format error")
      success_doc = create(:source_document, user: user, status: "success")

      create(:imported_transaction, user: user, source_document: success_doc, status: "unmatched")
      create(:imported_transaction, :confirmed_receipt, user: user, source_document: success_doc)

      # Other user records
      create(:source_document, user: other_user, status: "processing")
      create(:source_document, user: other_user, status: "failed")

      result = query.call

      expect(result.processing_documents).to contain_exactly(proc_doc1, proc_doc2)
      expect(result.failed_documents).to contain_exactly(fail_doc)
      expect(result.processing_count).to eq(2)
      expect(result.failed_count).to eq(1)
      expect(result.review_count).to eq(1)
      expect(result.history_count).to eq(1)
      expect(result.inbox_revision).to eq(user.inbox_revision)
    end

    it "falls back to locking user if revision changes during optimistic attempts" do
      call_count = 0
      allow(user).to receive(:inbox_revision) do
        call_count += 1
        call_count # changes every call
      end

      result = query.call
      expect(result).to be_a(ImportedTransactions::ProcessingQuery::ProcessingResult)
    end
  end
end
