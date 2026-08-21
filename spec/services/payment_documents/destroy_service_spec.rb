require "rails_helper"

RSpec.describe PaymentDocuments::DestroyService do
  let(:user) { create(:user) }

  it "destroys a document without confirmed ingestions" do
    doc = create(:payment_document, user: user)
    create(:payment_ingestion, user: user, payment_document: doc, status: :matched)

    expect {
      result = described_class.call(user: user, document: doc)
      expect(result).to be_success
    }.to change(PaymentDocument, :count).by(-1).and change(PaymentIngestion, :count).by(-1)
  end

  it "rejects destroying a document with confirmed ingestions" do
    doc = create(:payment_document, user: user)
    create(:payment_ingestion, user: user, payment_document: doc, status: :confirmed)

    expect {
      result = described_class.call(user: user, document: doc)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:immutable)
      expect(result.failure.error).to eq("Cannot delete document with confirmed payment ingestions")
    }.not_to change(PaymentDocument, :count)
  end

  it "returns failure when document belongs to another user" do
    other_user = create(:user)
    doc = create(:payment_document, user: other_user)

    result = described_class.call(user: user, document: doc)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:not_found)
  end
end
