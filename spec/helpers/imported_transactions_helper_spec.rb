require "rails_helper"

RSpec.describe ImportedTransactionsHelper, type: :helper do
  let(:user) { create(:user) }
  let(:party) { create(:party, user: user, display_name: "Jane Doe") }
  let(:source_document) { create(:source_document, user: user) }

  it "returns nil if matched_party is nil" do
    txn = build(:imported_transaction, user: user, matched_party: nil)
    expect(helper.imported_transaction_alias_proposal(txn)).to be_nil
  end

  it "suggests payer alias name if payer_name is candidate" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      matched_party: party,
      payer_name: "Jane D Doe"
    )

    expect(helper.imported_transaction_alias_proposal(txn)).to eq("Jane D Doe")
  end

  it "suggests payer username if payer_name is not candidate but payer_username is candidate" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      matched_party: party,
      payer_name: "Jane Doe",
      payer_username: "@janedoe"
    )

    expect(helper.imported_transaction_alias_proposal(txn)).to eq("@janedoe")
  end

  it "returns nil if neither name nor username is candidate" do
    txn = create(
      :imported_transaction,
      user: user,
      source_document: source_document,
      matched_party: party,
      payer_name: "Jane Doe",
      payer_username: nil
    )

    expect(helper.imported_transaction_alias_proposal(txn)).to be_nil
  end
end
