require "rails_helper"

RSpec.describe SourceDocuments::DestroyService do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:source_document) { create(:source_document, user: user) }

  describe "#call" do
    it "destroys document and cascades unconfirmed imported transactions" do
      txn = create(:imported_transaction, user: user, source_document: source_document, status: "pending")

      expect(ImportedTransactions::InboxBroadcastService).to receive(:call).with(
        user: user,
        deleted_document_id: source_document.id,
        deleted_transaction_ids: [ txn.id ]
      )

      expect {
        result = described_class.call(user: user, document: source_document)
        expect(result).to be_success
      }.to change(SourceDocument, :count).by(-1)
       .and change(ImportedTransaction, :count).by(-1)
    end

    it "prevents deleting document when confirmed transactions exist" do
      create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)
      expect {
        result = described_class.call(user: user, document: source_document)
        expect(result).to be_failure
        expect(result.failure.code).to eq(:immutable)
      }.to change(SourceDocument, :count).by(0)
    end

    it "rejects when document belongs to another user" do
      foreign_doc = create(:source_document, user: other_user)
      result = described_class.call(user: user, document: foreign_doc)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
    end

    it "handles ActiveRecord::RecordNotDestroyed" do
      allow(source_document).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed.new("Destroy error", source_document))
      result = described_class.call(user: user, document: source_document)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:destroy_failed)
    end

    it "serializes concurrent document destroy vs transaction confirm" do
      property = create(:property, user: user)
      unit = create(:rentable_unit, property: property)
      party = create(:party, user: user)
      tenancy = create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
      create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant")

      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle"
      )

      destroy_res = nil
      confirm_res = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          destroy_res = described_class.call(user: user, document: SourceDocument.find(source_document.id))
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          confirm_res = ImportedTransactions::ConfirmService.call(
            user: user,
            transaction: ImportedTransaction.find(txn.id)
          )
        end
      end

      [ t1, t2 ].each(&:join)

      if confirm_res.success?
        # Confirm won: document destroy must fail because confirmed child exists
        expect(destroy_res).to be_failure
        expect(destroy_res.failure.code).to eq(:immutable)
        expect(SourceDocument.where(id: source_document.id).exists?).to be(true)
        expect(Receipt.count).to eq(1)
      else
        # Destroy won: document and transaction deleted, confirm failed
        expect(destroy_res).to be_success
        expect(confirm_res).to be_failure
        expect(SourceDocument.where(id: source_document.id).exists?).to be(false)
        expect(Receipt.count).to eq(0)
      end
    end
  end
end
