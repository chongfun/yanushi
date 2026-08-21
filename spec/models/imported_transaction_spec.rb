require "rails_helper"

RSpec.describe ImportedTransaction, type: :model do
  let(:user) { create(:user) }
  let(:source_document) { create(:source_document, user: user) }
  let(:party) { create(:party, user: user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  describe "validations and scopes" do
    it "is valid with valid attributes" do
      txn = build(:imported_transaction, user: user, source_document: source_document)
      expect(txn).to be_valid
      expect(txn.accounting_user).to eq(user)
    end

    it "validates positive amount_cents" do
      expect(build(:imported_transaction, user: user, source_document: source_document, amount_cents: 0)).not_to be_valid
      expect(build(:imported_transaction, user: user, source_document: source_document, amount_cents: -100)).not_to be_valid
      expect(build(:imported_transaction, user: user, source_document: source_document, amount_cents: 50_000)).to be_valid
    end

    it "parses virtual amount to amount_cents" do
      txn = build(:imported_transaction, user: user, source_document: source_document)
      txn.amount = "1500.50"
      expect(txn.amount_cents).to eq(150_050)
      expect(txn.amount).to eq(BigDecimal("1500.50"))

      txn.amount = "2500"
      expect(txn.amount_cents).to eq(250_000)

      txn.amount = ""
      expect(txn.amount_cents).to be_nil

      txn.amount = "invalid"
      expect(txn).not_to be_valid
      expect(txn.errors[:amount]).to include("is not a valid number")

      txn.amount = "10.555"
      expect(txn).not_to be_valid
      expect(txn.errors[:amount]).to include("cannot have fractional cents")

      txn.amount = "-5.00"
      expect(txn).not_to be_valid
      expect(txn.errors[:amount]).to include("must be greater than 0")
    end

    it "normalizes payment_method and external_reference" do
      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        payment_method: "  ZELLE  ",
        external_reference: "  REF123  "
      )
      expect(txn.payment_method).to eq("zelle")
      expect(txn.external_reference).to eq("REF123")

      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        payment_method: nil,
        external_reference: ""
      )
      expect(txn2.payment_method).to be_nil
      expect(txn2.external_reference).to be_nil
    end

    it "filters reviewable scope" do
      t1 = create(:imported_transaction, user: user, source_document: source_document, status: "pending")
      t2 = create(:imported_transaction, user: user, source_document: source_document, status: "matched")
      t3 = create(:imported_transaction, user: user, source_document: source_document, status: "unmatched")
      t4 = create(:imported_transaction, user: user, source_document: source_document, status: "ambiguous")
      t5 = create(:imported_transaction, user: user, source_document: source_document, status: "failed")
      t6 = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)

      expect(described_class.reviewable).to contain_exactly(t2, t3, t4, t5)
      expect(described_class.confirmed).to contain_exactly(t6)
    end

    it "validates that source_document belongs to the same user" do
      other_user = create(:user)
      other_document = create(:source_document, user: other_user)

      txn = build(
        :imported_transaction,
        user: user,
        source_document: other_document
      )

      expect(txn).not_to be_valid
      expect(txn.errors[:source_document]).to include("must belong to the same user")
    end
  end

  describe "#confirmable?" do
    let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

    it "is false for unknown transaction_kind" do
      txn = build(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "unknown",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.current,
        payment_method: "zelle"
      )
      expect(txn.confirmable?).to be(false)
    end

    it "is true for valid tenant_receipt" do
      txn = build(
        :imported_transaction,
        :tenant_receipt,
        user: user,
        source_document: source_document,
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      expect(txn.confirmable?).to be(true)
    end

    it "is false for tenant_receipt missing payment_method" do
      txn = build(
        :imported_transaction,
        :tenant_receipt,
        user: user,
        source_document: source_document,
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.current,
        payment_method: nil
      )
      expect(txn.confirmable?).to be(false)
    end

    it "is true for valid security_deposit with existing deposit aggregate" do
      security_deposit # ensure exists
      txn = build(
        :imported_transaction,
        :security_deposit,
        user: user,
        source_document: source_document,
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      expect(txn.confirmable?).to be(true)
    end

    it "is false for security_deposit when tenancy has no security_deposit" do
      txn = build(
        :imported_transaction,
        :security_deposit,
        user: user,
        source_document: source_document,
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.current
      )
      expect(txn.confirmable?).to be(false)
    end

    it "is false when already confirmed" do
      txn = build(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)
      expect(txn.confirmable?).to be(false)
    end

    it "is false when matched_party or matched_tenancy is blank" do
      txn1 = build(:imported_transaction, :tenant_receipt, user: user, source_document: source_document, matched_party: nil, matched_tenancy: tenancy)
      txn2 = build(:imported_transaction, :tenant_receipt, user: user, source_document: source_document, matched_party: party, matched_tenancy: nil)
      expect(txn1.confirmable?).to be(false)
      expect(txn2.confirmable?).to be(false)
    end

    it "is false when amount_cents or occurred_on is missing" do
      txn1 = build(:imported_transaction, :tenant_receipt, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy, amount_cents: nil, occurred_on: Date.current)
      txn2 = build(:imported_transaction, :tenant_receipt, user: user, source_document: source_document, matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, occurred_on: nil)
      expect(txn1.confirmable?).to be(false)
      expect(txn2.confirmable?).to be(false)
    end

    it "checks reviewable predicate" do
      expect(build(:imported_transaction, status: "matched")).to be_reviewable
      expect(build(:imported_transaction, status: "unmatched")).to be_reviewable
      expect(build(:imported_transaction, status: "ambiguous")).to be_reviewable
      expect(build(:imported_transaction, status: "failed")).to be_reviewable
      expect(build(:imported_transaction, status: "pending")).not_to be_reviewable
      expect(build(:imported_transaction, status: "confirmed")).not_to be_reviewable
    end

    it "accepts numeric values for amount=" do
      txn = build(:imported_transaction, user: user, source_document: source_document)
      txn.amount = 125.50
      expect(txn.amount_cents).to eq(12550)
    end
  end

  describe "confirmed_source consistency validation" do
    it "validates that confirmed status requires confirmed_source" do
      txn = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", confirmed_source: nil)
      expect(txn).not_to be_valid
      expect(txn.errors[:confirmed_source]).to include("must be present for confirmed transaction")
    end

    it "validates that unconfirmed status cannot have confirmed_source" do
      receipt = create(:receipt, tenancy: tenancy, payer_party: party, user: user)
      txn = build(:imported_transaction, user: user, source_document: source_document, status: "matched", confirmed_source: receipt)
      expect(txn).not_to be_valid
      expect(txn.errors[:confirmed_source]).to include("must be blank for unconfirmed transaction")
    end

    it "validates that tenant_receipt must reference Receipt" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 100_000)
      dep_txn = create(:security_deposit_transaction, security_deposit: deposit, party: party, amount_cents: 100_000, occurred_on: Date.current)

      txn = build(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "confirmed",
        confirmed_source: dep_txn
      )
      expect(txn).not_to be_valid
      expect(txn.errors[:confirmed_source]).to include("must be a Receipt for tenant receipts")
    end

    it "validates that security_deposit must reference SecurityDepositTransaction" do
      receipt = create(:receipt, tenancy: tenancy, payer_party: party, user: user)

      txn = build(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "security_deposit",
        status: "confirmed",
        confirmed_source: receipt
      )
      expect(txn).not_to be_valid
      expect(txn.errors[:confirmed_source]).to include("must be a SecurityDepositTransaction for security deposits")
    end

    it "validates that confirmed transaction cannot have unknown transaction_kind" do
      receipt = create(:receipt, tenancy: tenancy, payer_party: party, user: user)
      txn = build(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "unknown",
        status: "confirmed",
        confirmed_source: receipt
      )
      expect(txn).not_to be_valid
      expect(txn.errors[:base]).to include("Unknown transaction kind cannot be confirmed")
    end

    it "rejects confirmed Receipt with nonexistent source ID" do
      txn = build(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "confirmed",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000
      )
      txn.confirmed_source_type = "Receipt"
      txn.confirmed_source_id = 999_999_999

      expect(txn).not_to be_valid
      expect(txn.errors[:confirmed_source]).to include("must reference an existing Receipt")
    end

    it "rejects confirmed SecurityDepositTransaction with nonexistent source ID" do
      txn = build(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "security_deposit",
        status: "confirmed",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000
      )
      txn.confirmed_source_type = "SecurityDepositTransaction"
      txn.confirmed_source_id = 999_999_999

      expect(txn).not_to be_valid
      expect(txn.errors[:confirmed_source]).to include("must reference an existing SecurityDepositTransaction")
    end

    it "validates that confirmed Receipt must match imported transaction user, tenancy, party, and amount" do
      other_user = create(:user)
      other_party_for_other_user = create(:party, user: other_user)
      other_prop_for_other_user = create(:property, user: other_user)
      other_unit_for_other_user = create(:rentable_unit, property: other_prop_for_other_user)
      other_tenancy_for_other_user = create(:tenancy, rentable_unit: other_unit_for_other_user)

      other_party = create(:party, user: user)
      other_unit = create(:rentable_unit, property: property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)

      # Mismatched user
      r_other_user = create(:receipt, tenancy: other_tenancy_for_other_user, payer_party: other_party_for_other_user, user: other_user, amount_cents: 100_000)
      txn1 = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "tenant_receipt", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, confirmed_source: r_other_user)
      expect(txn1).not_to be_valid
      expect(txn1.errors[:confirmed_source]).to include("accounting user must match imported transaction user")

      # Mismatched tenancy
      r_other_tenancy = create(:receipt, tenancy: other_tenancy, payer_party: party, user: user, amount_cents: 100_000)
      txn2 = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "tenant_receipt", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, confirmed_source: r_other_tenancy)
      expect(txn2).not_to be_valid
      expect(txn2.errors[:confirmed_source]).to include("tenancy must match matched tenancy")

      # Mismatched party
      r_other_party = create(:receipt, tenancy: tenancy, payer_party: other_party, user: user, amount_cents: 100_000)
      txn3 = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "tenant_receipt", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, confirmed_source: r_other_party)
      expect(txn3).not_to be_valid
      expect(txn3.errors[:confirmed_source]).to include("payer party must match matched party")

      # Mismatched amount
      r_other_amount = create(:receipt, tenancy: tenancy, payer_party: party, user: user, amount_cents: 50_000)
      txn4 = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "tenant_receipt", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, confirmed_source: r_other_amount)
      expect(txn4).not_to be_valid
      expect(txn4.errors[:confirmed_source]).to include("amount must match imported transaction amount")
    end

    it "validates that confirmed SecurityDepositTransaction must match imported transaction user, tenancy, party, amount, and kind" do
      other_party = create(:party, user: user)
      other_unit = create(:rentable_unit, property: property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_user = create(:user)
      other_prop = create(:property, user: other_user)
      other_user_unit = create(:rentable_unit, property: other_prop)
      other_user_tenancy = create(:tenancy, rentable_unit: other_user_unit)
      other_user_party = create(:party, user: other_user)

      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      other_deposit = create(:security_deposit, tenancy: other_tenancy, required_amount_cents: 200_000)
      other_user_deposit = create(:security_deposit, tenancy: other_user_tenancy, required_amount_cents: 200_000)

      # Mismatched user
      d_other_user = create(:security_deposit_transaction, security_deposit: other_user_deposit, party: other_user_party, amount_cents: 100_000, transaction_kind: "received", occurred_on: Date.current)
      txn1 = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "security_deposit", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, confirmed_source: d_other_user)
      expect(txn1).not_to be_valid
      expect(txn1.errors[:confirmed_source]).to include("accounting user must match imported transaction user")

      # Mismatched transaction_kind (e.g. refunded)
      d_refunded = create(:security_deposit_transaction, security_deposit: deposit, party: party, amount_cents: 100_000, transaction_kind: "refunded", occurred_on: Date.current)
      txn2 = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "security_deposit", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, confirmed_source: d_refunded)
      expect(txn2).not_to be_valid
      expect(txn2.errors[:confirmed_source]).to include("transaction kind must be received")

      # Mismatched tenancy
      d_other_tenancy = create(:security_deposit_transaction, security_deposit: other_deposit, party: party, amount_cents: 100_000, transaction_kind: "received", occurred_on: Date.current)
      txn3 = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "security_deposit", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, confirmed_source: d_other_tenancy)
      expect(txn3).not_to be_valid
      expect(txn3.errors[:confirmed_source]).to include("tenancy must match matched tenancy")

      # Mismatched party
      d_other_party = create(:security_deposit_transaction, security_deposit: deposit, party: other_party, amount_cents: 100_000, transaction_kind: "received", occurred_on: Date.current)
      txn4 = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "security_deposit", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, confirmed_source: d_other_party)
      expect(txn4).not_to be_valid
      expect(txn4.errors[:confirmed_source]).to include("party must match matched party")

      # Mismatched amount
      d_other_amount = create(:security_deposit_transaction, security_deposit: deposit, party: party, amount_cents: 50_000, transaction_kind: "received", occurred_on: Date.current)
      txn5 = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "security_deposit", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, confirmed_source: d_other_amount)
      expect(txn5).not_to be_valid
      expect(txn5.errors[:confirmed_source]).to include("amount must match imported transaction amount")
    end

    it "enforces DB check constraint: status == confirmed IFF confirmed_source present" do
      receipt = create(:receipt, tenancy: tenancy, payer_party: party, user: user, amount_cents: 100_000)

      # 1. status = confirmed without confirmed_source
      expect {
        build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", confirmed_source: nil).save(validate: false)
      }.to raise_error(ActiveRecord::StatementInvalid)

      # 2. status != confirmed with confirmed_source present
      expect {
        build(:imported_transaction, user: user, source_document: source_document, status: "matched", confirmed_source: receipt).save(validate: false)
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "rejects confirmed Receipt with wrong date, payment_method, or external_reference" do
      jan_receipt = create(:receipt, tenancy: tenancy, payer_party: party, user: user, amount_cents: 200_000, received_on: Date.new(2026, 1, 1), payment_method: "zelle", external_reference: "JAN123")

      # Import is for February - same broad dimensions but wrong date
      txn_wrong_date = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "tenant_receipt", matched_party: party, matched_tenancy: tenancy, amount_cents: 200_000, occurred_on: Date.new(2026, 2, 1), payment_method: "zelle", external_reference: "JAN123", confirmed_source: jan_receipt)
      expect(txn_wrong_date).not_to be_valid
      expect(txn_wrong_date.errors[:confirmed_source]).to include("received date must match imported transaction date")

      # Wrong payment_method
      txn_wrong_method = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "tenant_receipt", matched_party: party, matched_tenancy: tenancy, amount_cents: 200_000, occurred_on: Date.new(2026, 1, 1), payment_method: "venmo", external_reference: "JAN123", confirmed_source: jan_receipt)
      expect(txn_wrong_method).not_to be_valid
      expect(txn_wrong_method.errors[:confirmed_source]).to include("payment method must match imported transaction payment method")

      # Wrong external_reference
      txn_wrong_ref = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "tenant_receipt", matched_party: party, matched_tenancy: tenancy, amount_cents: 200_000, occurred_on: Date.new(2026, 1, 1), payment_method: "zelle", external_reference: "FEB456", confirmed_source: jan_receipt)
      expect(txn_wrong_ref).not_to be_valid
      expect(txn_wrong_ref.errors[:confirmed_source]).to include("external reference must match imported transaction external reference")
    end

    it "rejects confirmed SecurityDepositTransaction with wrong date or external_reference" do
      other_unit = create(:rentable_unit, property: property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)

      jan_deposit_txn = create(:security_deposit_transaction, security_deposit: deposit, party: party, amount_cents: 100_000, transaction_kind: "received", occurred_on: Date.new(2026, 1, 15), external_reference: "DEP-JAN")

      # Wrong date
      txn_wrong_date = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "security_deposit", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, occurred_on: Date.new(2026, 2, 15), external_reference: "DEP-JAN", confirmed_source: jan_deposit_txn)
      expect(txn_wrong_date).not_to be_valid
      expect(txn_wrong_date.errors[:confirmed_source]).to include("occurred date must match imported transaction date")

      # Wrong external_reference
      txn_wrong_ref = build(:imported_transaction, user: user, source_document: source_document, status: "confirmed", transaction_kind: "security_deposit", matched_party: party, matched_tenancy: tenancy, amount_cents: 100_000, occurred_on: Date.new(2026, 1, 15), external_reference: "DEP-FEB", confirmed_source: jan_deposit_txn)
      expect(txn_wrong_ref).not_to be_valid
      expect(txn_wrong_ref.errors[:confirmed_source]).to include("external reference must match imported transaction external reference")
    end
  end

  describe "immutability and delete protection when confirmed" do
    let(:confirmed_txn) { create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document) }

    it "prevents modification of fields after confirmed" do
      expect(confirmed_txn.update(amount_cents: 200_000)).to be(false)
      expect(confirmed_txn.errors[:base]).to include("Cannot modify a confirmed imported transaction")
    end

    it "prevents destroy once confirmed" do
      expect(confirmed_txn.destroy).to be(false)
      expect(confirmed_txn.errors[:base]).to include("Cannot delete a confirmed imported transaction")
      expect(described_class.exists?(confirmed_txn.id)).to be(true)
    end
  end
end
