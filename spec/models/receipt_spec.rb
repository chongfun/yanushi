require "rails_helper"

RSpec.describe Receipt, type: :model do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:payer_party) { create(:party, user: user) }

  subject(:receipt) do
    build(:receipt,
      tenancy: tenancy,
      user: user,
      payer_party: payer_party,
      amount_cents: 100_000,
      received_on: Date.current,
      payment_method: "zelle",
      external_reference: "ZELLE123",
      memo: "January Rent"
    )
  end

  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:tenancy) }
    it { is_expected.to belong_to(:payer_party).class_name("Party") }
    it { is_expected.to belong_to(:superseded_by).class_name("Receipt").optional }
    it { is_expected.to have_one(:superseded_receipt).class_name("Receipt").with_foreign_key(:superseded_by_id) }
    it { is_expected.to have_many(:journal_entries).dependent(:restrict_with_error) }
  end

  describe "validations" do
    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:received_on) }
    it { is_expected.to validate_presence_of(:payment_method) }

    it "requires amount_cents to be strictly positive" do
      receipt.amount_cents = 0
      expect(receipt).not_to be_valid
      expect(receipt.errors[:amount_cents]).to include("must be greater than 0")

      receipt.amount_cents = -100
      expect(receipt).not_to be_valid
    end

    it "validates that tenancy belongs to the same user" do
      other_user = create(:user)
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)

      receipt.tenancy = other_tenancy
      expect(receipt).not_to be_valid
      expect(receipt.errors[:tenancy]).to include("must belong to the receipt owner")
    end

    it "validates that payer party belongs to the same user" do
      other_user = create(:user)
      other_party = create(:party, user: other_user)

      receipt.payer_party = other_party
      expect(receipt).not_to be_valid
      expect(receipt.errors[:payer_party]).to include("must belong to the receipt owner")
    end

    it "allows payer party who is not a participant in the tenancy" do
      external_party = create(:party, user: user, display_name: "Parent / Employer")
      receipt.payer_party = external_party
      expect(receipt).to be_valid
    end
  end

  describe "normalizations" do
    it "downcases and strips payment_method" do
      r = create(:receipt, tenancy: tenancy, payer_party: payer_party, payment_method: "  ZelLE  ")
      expect(r.payment_method).to eq("zelle")
    end

    it "strips external_reference and converts blank to nil" do
      r = create(:receipt, tenancy: tenancy, payer_party: payer_party, external_reference: "  REF123  ")
      expect(r.external_reference).to eq("REF123")

      r2 = create(:receipt, tenancy: tenancy, payer_party: payer_party, external_reference: "   ")
      expect(r2.external_reference).to be_nil
    end
  end

  describe "external reference uniqueness" do
    it "prevents duplicate active external references for the same user and method" do
      create(:receipt,
        user: user,
        tenancy: tenancy,
        payer_party: payer_party,
        payment_method: "zelle",
        external_reference: "TXN100"
      )

      dup = build(:receipt,
        user: user,
        tenancy: tenancy,
        payer_party: payer_party,
        payment_method: "zelle",
        external_reference: "TXN100"
      )

      expect(dup).not_to be_valid
      expect(dup.errors[:external_reference]).to include("has already been taken")
    end

    it "allows same external reference for different payment methods" do
      create(:receipt,
        user: user,
        tenancy: tenancy,
        payer_party: payer_party,
        payment_method: "zelle",
        external_reference: "TXN100"
      )

      diff_method = build(:receipt,
        user: user,
        tenancy: tenancy,
        payer_party: payer_party,
        payment_method: "venmo",
        external_reference: "TXN100"
      )

      expect(diff_method).to be_valid
    end

    it "allows same external reference for different users" do
      create(:receipt,
        user: user,
        tenancy: tenancy,
        payer_party: payer_party,
        payment_method: "zelle",
        external_reference: "TXN100"
      )

      other_user = create(:user)
      other_prop = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_prop)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_party = create(:party, user: other_user)

      other_receipt = build(:receipt,
        user: other_user,
        tenancy: other_tenancy,
        payer_party: other_party,
        payment_method: "zelle",
        external_reference: "TXN100"
      )

      expect(other_receipt).to be_valid
    end

    it "allows reusing external reference when prior receipt is voided" do
      r1 = create(:receipt,
        user: user,
        tenancy: tenancy,
        payer_party: payer_party,
        payment_method: "zelle",
        external_reference: "TXN100"
      )
      r1.update_columns(voided_at: Time.current)

      r2 = build(:receipt,
        user: user,
        tenancy: tenancy,
        payer_party: payer_party,
        payment_method: "zelle",
        external_reference: "TXN100"
      )

      expect(r2).to be_valid
    end
  end

  describe "amount helpers and fractional cent validation" do
    it "returns decimal amount from amount_cents" do
      receipt.amount_cents = 125_050
      expect(receipt.amount).to eq(BigDecimal("1250.50"))
    end

    it "accepts valid amount assignments" do
      receipt.amount = "250.75"
      expect(receipt.amount_cents).to eq(25_075)

      receipt.amount = 300
      expect(receipt.amount_cents).to eq(30_000)
    end

    it "rejects fractional cent assignments without silent rounding" do
      receipt.amount = "100.005"
      expect(receipt).not_to be_valid
      expect(receipt.errors[:amount]).to include("cannot have fractional cents")
    end

    it "handles malformed amount strings gracefully" do
      receipt.amount = "not-a-number"
      expect(receipt).not_to be_valid
      expect(receipt.errors[:amount]).to include("is not a valid number")
    end
  end

  describe "lifecycle methods and immutability" do
    let!(:posted_receipt) do
      r = create(:receipt, tenancy: tenancy, payer_party: payer_party, amount_cents: 100_000)
      r.update_columns(posted_at: Time.current)
      r
    end

    it "correctly reports posted?, voided?, superseded?, active?" do
      expect(receipt.posted?).to be false
      expect(receipt.active?).to be true

      expect(posted_receipt.posted?).to be true
      expect(posted_receipt.voided?).to be false
      expect(posted_receipt.active?).to be true

      posted_receipt.update_columns(voided_at: Time.current)
      expect(posted_receipt.voided?).to be true
      expect(posted_receipt.active?).to be false
    end

    it "rejects changes to financial and metadata fields once posted" do
      posted_receipt.amount_cents = 200_000
      expect(posted_receipt).not_to be_valid
      expect(posted_receipt.errors[:base]).to include("Posted receipts are immutable records")

      posted_receipt.reload
      posted_receipt.received_on = 1.week.ago.to_date
      expect(posted_receipt).not_to be_valid

      posted_receipt.reload
      posted_receipt.payment_method = "cash"
      expect(posted_receipt).not_to be_valid
    end

    it "rejects direct ActiveRecord updates to voided_at, posted_at, and superseded_by_id" do
      posted_receipt.voided_at = Time.current
      expect(posted_receipt).not_to be_valid
      expect(posted_receipt.errors[:voided_at]).to include("cannot be modified directly; use Receipts::VoidService or Receipts::CorrectService")

      posted_receipt.reload
      posted_receipt.posted_at = nil
      expect(posted_receipt).not_to be_valid
      expect(posted_receipt.errors[:posted_at]).to include("cannot be modified directly once posted")

      posted_receipt.reload
      posted_receipt.superseded_by = create(:receipt, tenancy: tenancy, payer_party: payer_party)
      expect(posted_receipt).not_to be_valid
      expect(posted_receipt.errors[:superseded_by_id]).to include("cannot be modified directly; use Receipts::CorrectService")
    end

    it "prevents deletion of posted receipts" do
      expect {
        posted_receipt.destroy
      }.not_to change(Receipt, :count)

      expect(posted_receipt.errors[:base]).to include("Cannot delete a posted receipt")
    end

    it "validates that superseded_by belongs to the same user" do
      other_user = create(:user)
      other_party = create(:party, user: other_user)
      other_prop = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_prop)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_receipt = create(:receipt, user: other_user, tenancy: other_tenancy, payer_party: other_party)

      unposted_receipt = build(:receipt, user: user, tenancy: tenancy, payer_party: payer_party, superseded_by: other_receipt)
      expect(unposted_receipt).not_to be_valid
      expect(unposted_receipt.errors[:superseded_by]).to include("must belong to the same user")
    end
  end
end
