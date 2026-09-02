require "rails_helper"

RSpec.describe ImportedTransactions::HistoryQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:query) { described_class.new(user: user) }

  describe "#call" do
    it "returns paginated confirmed transactions for the user" do
      source_doc = create(:source_document, user: user, status: "success")
      confirmed_txn1 = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_doc, occurred_on: 2.days.ago)
      confirmed_txn2 = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_doc, occurred_on: 1.day.ago)
      reviewable_txn = create(:imported_transaction, user: user, source_document: source_doc, status: "matched")

      other_doc = create(:source_document, user: other_user, status: "success")
      other_confirmed = create(:imported_transaction, :confirmed_receipt, user: other_user, source_document: other_doc)

      result = query.call(page: 1, per_page: 10)

      expect(result.confirmed_transactions).to eq([ confirmed_txn2, confirmed_txn1 ])
      expect(result.confirmed_transactions).not_to include(reviewable_txn, other_confirmed)
      expect(result.page).to eq(1)
      expect(result.per_page).to eq(10)
      expect(result.total_confirmed_count).to eq(2)
      expect(result.total_pages).to eq(1)
      expect(result.filters).to eq({})
    end

    it "filters by search term matching payer or reference" do
      source_doc = create(:source_document, user: user, status: "success")
      party = create(:party, user: user, display_name: "Alice Walker")
      txn_alice = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_doc, matched_party: party, external_reference: "ZEL-100")
      _txn_bob = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_doc, payer_name: "Bob Builder", external_reference: "CHK-200")

      result = query.call(filters: { search: "Alice" })
      expect(result.confirmed_transactions).to eq([ txn_alice ])
      expect(result.total_confirmed_count).to eq(1)

      ref_result = query.call(filters: { search: "CHK-200" })
      expect(ref_result.confirmed_transactions.size).to eq(1)
    end

    it "filters by payment method" do
      source_doc = create(:source_document, user: user, status: "success")
      txn_zelle = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_doc, payment_method: "zelle")
      _txn_check = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_doc, payment_method: "check")

      result = query.call(filters: { payment_method: "zelle" })
      expect(result.confirmed_transactions).to eq([ txn_zelle ])
      expect(result.total_confirmed_count).to eq(1)
    end

    it "handles multi-page pagination correctly" do
      source_doc = create(:source_document, user: user, status: "success")
      Array.new(5) do |i|
        create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_doc, occurred_on: i.days.ago)
      end

      page1_result = query.call(page: 1, per_page: 2)
      expect(page1_result.confirmed_transactions.size).to eq(2)
      expect(page1_result.page).to eq(1)
      expect(page1_result.total_pages).to eq(3)
      expect(page1_result.total_confirmed_count).to eq(5)

      page2_result = query.call(page: 2, per_page: 2)
      expect(page2_result.confirmed_transactions.size).to eq(2)
      expect(page2_result.page).to eq(2)

      page3_result = query.call(page: 3, per_page: 2)
      expect(page3_result.confirmed_transactions.size).to eq(1)
      expect(page3_result.page).to eq(3)
    end

    it "preloads nested tenancy and property associations on polymorphic confirmed sources without N+1 queries" do
      property = create(:property, user: user)
      unit = create(:rentable_unit, property: property)
      party = create(:party, user: user)
      tenancy = create(:tenancy, rentable_unit: unit)
      source_doc = create(:source_document, user: user, status: "success")

      # Create 3 confirmed receipts
      3.times do |i|
        receipt = create(:receipt, user: user, tenancy: tenancy, payer_party: party, payment_method: "zelle", external_reference: "REF-REC-#{i}", amount_cents: 100_000 + i, received_on: i.days.ago)
        create(
          :imported_transaction,
          user: user,
          source_document: source_doc,
          transaction_kind: "tenant_receipt",
          status: "confirmed",
          matched_party: party,
          matched_tenancy: tenancy,
          payment_method: "zelle",
          external_reference: "REF-REC-#{i}",
          confirmed_source: receipt,
          amount_cents: receipt.amount_cents,
          occurred_on: receipt.received_on
        )
      end

      # Create 3 confirmed security deposits
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      3.times do |i|
        dep_txn = create(:security_deposit_transaction, security_deposit: deposit, party: party, external_reference: "REF-DEP-#{i}", amount_cents: 50_000 + i, occurred_on: i.days.ago)
        create(
          :imported_transaction,
          user: user,
          source_document: source_doc,
          transaction_kind: "security_deposit",
          status: "confirmed",
          matched_party: party,
          matched_tenancy: tenancy,
          payment_method: "zelle",
          external_reference: "REF-DEP-#{i}",
          confirmed_source: dep_txn,
          amount_cents: dep_txn.amount_cents,
          occurred_on: dep_txn.occurred_on
        )
      end

      result = query.call(page: 1, per_page: 10)
      txns = result.confirmed_transactions
      expect(txns.size).to eq(6)

      # Traversing view association graph should fire ZERO additional queries
      queries = []
      counter = ->(_name, _started, _finished, _unique_id, payload) {
        queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA CACHE])
      }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        txns.each do |txn|
          if txn.confirmed_source.is_a?(Receipt)
            expect(txn.confirmed_source.tenancy.property.address).to eq(property.address)
          elsif txn.confirmed_source.is_a?(SecurityDepositTransaction)
            expect(txn.confirmed_source.security_deposit.tenancy.property.address).to eq(property.address)
          end
        end
      end

      expect(queries).to be_empty
    end

    it "handles zero confirmed transactions gracefully" do
      result = query.call(page: 1, per_page: 20)

      expect(result.confirmed_transactions).to be_empty
      expect(result.page).to eq(1)
      expect(result.per_page).to eq(20)
      expect(result.total_confirmed_count).to eq(0)
      expect(result.total_pages).to eq(0)
    end
  end
end
