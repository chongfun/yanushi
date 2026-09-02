require "rails_helper"

RSpec.describe ImportedTransactions::InboxQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:query) { described_class.new(user: user) }

  describe "#call" do
    it "returns reviewable transactions and documents scoped to the user" do
      processing_doc = create(:source_document, user: user, status: "processing")
      failed_doc = create(:source_document, user: user, status: "failed", error_message: "Corrupted PDF")
      success_doc = create(:source_document, user: user, status: "success")

      matched_txn = create(:imported_transaction, user: user, source_document: success_doc, status: "matched")
      unmatched_txn = create(:imported_transaction, user: user, source_document: success_doc, status: "unmatched")
      ambiguous_txn = create(:imported_transaction, user: user, source_document: success_doc, status: "ambiguous")
      failed_txn = create(:imported_transaction, user: user, source_document: success_doc, status: "failed")
      confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: success_doc)

      # Other user records
      other_doc = create(:source_document, user: other_user, status: "processing")
      other_txn = create(:imported_transaction, user: other_user, status: "matched")

      result = query.call

      expect(result.reviewable_transactions).to contain_exactly(matched_txn, unmatched_txn, ambiguous_txn, failed_txn)
      expect(result.reviewable_transactions).not_to include(confirmed_txn, other_txn)
      expect(result.review_count).to eq(4)
      expect(result.processing_count).to eq(1)
      expect(result.failed_count).to eq(1)
    end

    it "returns zero counts when no reviewable transactions or documents exist" do
      result = query.call

      expect(result.reviewable_transactions).to be_empty
      expect(result.review_count).to eq(0)
      expect(result.processing_documents).to be_empty
      expect(result.processing_count).to eq(0)
      expect(result.failed_documents).to be_empty
      expect(result.failed_count).to eq(0)
      expect(result.inbox_revision).to eq(user.inbox_revision)
    end

    it "reflects the incremented inbox_revision when mutations occur" do
      expect(query.call.inbox_revision).to eq(0)

      user.increment_inbox_revision!
      expect(query.call.inbox_revision).to eq(1)
    end

    it "fetches updated_transaction within the snapshot when updated_transaction_id is supplied" do
      doc = create(:source_document, user: user, status: "success")
      txn = create(:imported_transaction, user: user, source_document: doc, status: "matched", amount_cents: 150_000)

      result = described_class.new(user: user, load_records: false, updated_transaction_id: txn.id).call
      expect(result.updated_transaction).to eq(txn)
      expect(result.updated_transaction.amount_cents).to eq(150_000)
    end

    it "populates next_transaction and updated_transaction_position without loading all reviewable records when load_records is false" do
      doc = create(:source_document, user: user, status: "success")
      txn2 = create(:imported_transaction, user: user, source_document: doc, status: "unmatched", created_at: 2.hours.ago)
      txn1 = create(:imported_transaction, user: user, source_document: doc, status: "matched", created_at: 1.hour.ago)

      result = described_class.new(user: user, load_records: false, updated_transaction_id: txn2.id).call
      expect(result.reviewable_transactions).to be_empty
      expect(result.review_count).to eq(2)
      expect(result.next_transaction).to eq(txn1)
      expect(result.updated_transaction).to eq(txn2)
      expect(result.updated_transaction_position).to eq(2)
    end

    it "retries and maintains revision-consistent position and counts when mutations occur during snapshot" do
      doc = create(:source_document, user: user, status: "success")
      txn2 = create(:imported_transaction, user: user, source_document: doc, status: "unmatched", created_at: 2.hours.ago)
      txn1 = create(:imported_transaction, user: user, source_document: doc, status: "matched", created_at: 1.hour.ago)

      query = described_class.new(user: user, load_records: false, updated_transaction_id: txn2.id)

      mutation_injected = false
      allow(query).to receive(:fetch_updated_transaction_position).and_wrap_original do |original, *args|
        pos = original.call(*args)
        if !mutation_injected
          mutation_injected = true
          create(:imported_transaction, user: user, source_document: doc, status: "unmatched", created_at: Time.current)
          user.increment_inbox_revision!
        end
        pos
      end

      result = query.call
      expect(result.review_count).to eq(3)
      expect(result.updated_transaction_position).to eq(3)
      expect(result.inbox_revision).to eq(user.reload.inbox_revision)
    end
  end
end
