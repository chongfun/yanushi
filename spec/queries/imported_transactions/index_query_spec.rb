require "rails_helper"

RSpec.describe ImportedTransactions::IndexQuery do
  let(:user) { create(:user) }
  let(:query) { described_class.new(user: user) }

  it "returns reviewable transactions, confirmed transactions, and documents with pagination" do
    source_doc = create(:source_document, user: user, status: "processing")
    failed_doc = create(:source_document, user: user, status: "failed", error_message: "Corrupted")
    reviewable_txn = create(:imported_transaction, user: user, source_document: source_doc, status: "matched")
    confirmed_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_doc)

    result = query.call(page: 1, per_page: 10)

    expect(result.reviewable_transactions).to include(reviewable_txn)
    expect(result.confirmed_transactions).to include(confirmed_txn)
    expect(result.processing_documents).to include(source_doc)
    expect(result.failed_documents).to include(failed_doc)
    expect(result.page).to eq(1)
    expect(result.per_page).to eq(10)
    expect(result.total_confirmed_count).to eq(1)
    expect(result.total_pages).to eq(1)
  end
end
