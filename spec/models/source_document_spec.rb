require "rails_helper"

RSpec.describe SourceDocument, type: :model do
  let(:user) { create(:user) }
  let(:source_document) { create(:source_document, user: user) }

  describe "validations" do
    it "is valid with valid attributes" do
      expect(source_document).to be_valid
    end

    it "requires user, status, and document_type" do
      expect(build(:source_document, user: nil)).not_to be_valid
      expect(build(:source_document, attachment_file: nil)).not_to be_valid
      expect(build(:source_document, attachment_filename: nil)).not_to be_valid
      expect(build(:source_document, attachment_content_type: nil)).not_to be_valid
    end

    it "computes attachment_sha256 from attachment_file automatically" do
      doc = create(:source_document, user: user, attachment_file: "my sample pdf")
      expect(doc.attachment_sha256).to eq(Digest::SHA256.hexdigest("my sample pdf"))
    end

    it "enforces attachment_sha256 uniqueness scoped to user" do
      create(:source_document, user: user, attachment_file: "identical bytes")
      dup = build(:source_document, user: user, attachment_file: "identical bytes")

      expect(dup).not_to be_valid
      expect(dup.errors[:attachment_sha256]).to include("has already been uploaded")

      # Allowed for different user
      other_user = create(:user)
      other_doc = build(:source_document, user: other_user, attachment_file: "identical bytes")
      expect(other_doc).to be_valid
    end
  end

  describe "preventing destroy with confirmed transactions" do
    it "allows destroy when transactions are unconfirmed" do
      create(:imported_transaction, source_document: source_document, user: user, status: "pending")
      expect { source_document.destroy }.to change(SourceDocument, :count).by(-1)
    end

    it "prevents destroy when a confirmed transaction exists" do
      create(:imported_transaction, :confirmed_receipt, source_document: source_document, user: user)
      expect(source_document.destroy).to be(false)
      expect(source_document.errors[:base]).to include("Cannot delete document with confirmed transactions")
      expect(SourceDocument.exists?(source_document.id)).to be(true)
    end
  end

  describe "immutability" do
    let(:other_user) { create(:user) }

    it "prevents updating user_id after document creation" do
      expect(source_document.update(user: other_user)).to be(false)
      expect(source_document.errors[:user]).to include("cannot be changed after document creation")
    end

    it "prevents updating attachment attributes immediately after document creation" do
      expect(source_document.update(attachment_file: "new binary content")).to be(false)
      expect(source_document.errors[:base]).to include("Cannot modify attachment after document creation")

      expect(source_document.update(attachment_filename: "different.pdf")).to be(false)
      expect(source_document.errors[:base]).to include("Cannot modify attachment after document creation")

      expect(source_document.update(attachment_content_type: "application/octet-stream")).to be(false)
      expect(source_document.errors[:base]).to include("Cannot modify attachment after document creation")
    end

    it "allows updating status, error_message, and document_type when unconfirmed" do
      expect(source_document.update(status: "success", document_type: "zelle", error_message: "none")).to be(true)
    end

    it "prevents modifying status, document_type, or error_message once confirmed transactions exist" do
      create(:imported_transaction, :confirmed_receipt, source_document: source_document, user: user)

      expect(source_document.update(status: "failed")).to be(false)
      expect(source_document.errors[:base]).to include("Cannot modify a document with confirmed transactions")

      expect(source_document.update(document_type: "venmo")).to be(false)
      expect(source_document.errors[:base]).to include("Cannot modify a document with confirmed transactions")

      expect(source_document.update(error_message: "Some error")).to be(false)
      expect(source_document.errors[:base]).to include("Cannot modify a document with confirmed transactions")
    end

    it "preserves same-document idempotency boundary after confirmation" do
      source_document.update!(status: "success")

      txn = create(
        :imported_transaction,
        :confirmed_receipt,
        source_document: source_document,
        user: user,
        payment_method: "p2p",
        external_reference: nil
      )

      # Status mutation rejected
      expect(source_document.update(status: "failed")).to be(false)
      expect(source_document.reload.status).to eq("success")

      # Re-processing returns existing candidates without creating duplicates
      expect {
        result = ImportedTransactions::IngestionService.call(user: user, pdf_path_or_io: source_document)
        expect(result).to be_success
        expect(result.value!.data[:imported_transactions]).to contain_exactly(txn)
      }.not_to change(ImportedTransaction, :count)
    end
  end
end
