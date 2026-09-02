require "rails_helper"

RSpec.describe ImportedTransactions::DestroyService do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:source_document) { create(:source_document, user: user) }

  describe "#call" do
    it "destroys an unconfirmed imported transaction" do
      txn = create(:imported_transaction, user: user, source_document: source_document, status: "pending")
      expect {
        result = described_class.call(user: user, transaction: txn)
        expect(result).to be_success
      }.to change(ImportedTransaction, :count).by(-1)
    end

    it "prevents deleting a confirmed imported transaction" do
      confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)
      expect {
        result = described_class.call(user: user, transaction: confirmed_txn)
        expect(result).to be_failure
        expect(result.failure.code).to eq(:immutable)
      }.to change(ImportedTransaction, :count).by(0)
    end

    it "rejects when transaction belongs to another user" do
      foreign_txn = create(:imported_transaction, user: other_user)
      result = described_class.call(user: user, transaction: foreign_txn)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
    end

    it "rejects deletion when submitted lock_version is stale" do
      txn = create(:imported_transaction, user: user, source_document: source_document, status: "pending", amount_cents: 100_000)
      txn.update!(amount_cents: 150_000)
      expect(txn.lock_version).to eq(1)

      expect {
        result = described_class.call(user: user, transaction: txn, lock_version: 0)
        expect(result).to be_failure
        expect(result.failure.code).to eq(:conflict)
        expect(result.failure.error).to include("updated in another session")
      }.not_to change(ImportedTransaction, :count)
    end

    it "handles ActiveRecord::RecordNotDestroyed" do
      txn = create(:imported_transaction, user: user, source_document: source_document, status: "pending")
      allow(txn).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed.new("Destroy error", txn))
      result = described_class.call(user: user, transaction: txn)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:destroy_failed)
    end

    it "returns :gone failure when record is deleted from DB before lock acquisition" do
      txn = create(:imported_transaction, user: user, source_document: source_document, status: "pending")
      txn_id = txn.id
      ImportedTransaction.where(id: txn_id).delete_all

      result = described_class.call(user: user, transaction: txn)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:gone)
      expect(result.failure.error).to include("not found")
    end
  end
end
