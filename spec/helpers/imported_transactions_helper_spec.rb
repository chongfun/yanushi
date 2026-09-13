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

  describe "#imported_transaction_source_description" do
    it "formats payment method and username when username is present" do
      txn = build(:imported_transaction, payment_method: "venmo", payer_username: "@janedoe", raw_text: "Venmo Payment")
      expect(helper.imported_transaction_source_description(txn)).to eq("Venmo · “@janedoe”")
    end

    it "formats payment method and raw text description for Chase statement import without username" do
      txn = build(:imported_transaction, payment_method: "zelle", payer_username: nil, raw_text: "HSIMPSON RENT AUG")
      expect(helper.imported_transaction_source_description(txn)).to eq("Zelle · “HSIMPSON RENT AUG”")
    end

    it "formats payment method and external reference when raw text and username are absent" do
      txn = build(:imported_transaction, payment_method: "check", payer_username: nil, raw_text: nil, external_reference: "CHK-999")
      expect(helper.imported_transaction_source_description(txn)).to eq("Check · “CHK-999”")
    end

    it "returns titleized payment method when no descriptive fields are present" do
      txn = build(:imported_transaction, payment_method: "cash", payer_username: nil, raw_text: nil, external_reference: nil, payer_name: nil)
      expect(helper.imported_transaction_source_description(txn)).to eq("Cash")
    end
  end
end
