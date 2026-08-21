require "rails_helper"

RSpec.describe SecurityDepositTransaction, type: :model do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:other_user) { create(:user) }
  let(:other_party) { create(:party, user: other_user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }
  let(:charge) { create(:charge, tenancy: tenancy, amount_cents: 50_000) }

  describe "validations" do
    it "is valid for received transaction with party and no charge" do
      txn = build(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party)
      expect(txn).to be_valid
    end

    it "is valid for refunded transaction with party and no charge" do
      txn = build(:security_deposit_transaction, :refunded, security_deposit: security_deposit, party: party)
      expect(txn).to be_valid
    end

    it "is valid for applied transaction with charge and no party" do
      txn = build(:security_deposit_transaction, :applied, security_deposit: security_deposit, charge: charge)
      expect(txn).to be_valid
    end

    it "rejects received transaction without party" do
      txn = build(:security_deposit_transaction, transaction_kind: "received", security_deposit: security_deposit, party: nil)
      expect(txn).not_to be_valid
      expect(txn.errors[:party]).to be_present
    end

    it "rejects received transaction with charge" do
      txn = build(:security_deposit_transaction, transaction_kind: "received", security_deposit: security_deposit, party: party, charge: charge)
      expect(txn).not_to be_valid
      expect(txn.errors[:charge]).to be_present
    end

    it "rejects refunded transaction without party" do
      txn = build(:security_deposit_transaction, transaction_kind: "refunded", security_deposit: security_deposit, party: nil)
      expect(txn).not_to be_valid
      expect(txn.errors[:party]).to be_present
    end

    it "rejects refunded transaction with charge" do
      txn = build(:security_deposit_transaction, transaction_kind: "refunded", security_deposit: security_deposit, party: party, charge: charge)
      expect(txn).not_to be_valid
      expect(txn.errors[:charge]).to be_present
    end

    it "rejects applied transaction without charge" do
      txn = build(:security_deposit_transaction, transaction_kind: "applied", security_deposit: security_deposit, charge: nil)
      expect(txn).not_to be_valid
      expect(txn.errors[:charge]).to be_present
    end

    it "rejects applied transaction with party" do
      txn = build(:security_deposit_transaction, transaction_kind: "applied", security_deposit: security_deposit, charge: charge, party: party)
      expect(txn).not_to be_valid
      expect(txn.errors[:party]).to be_present
    end

    it "rejects party from another user" do
      txn = build(:security_deposit_transaction, :received, security_deposit: security_deposit, party: other_party)
      expect(txn).not_to be_valid
      expect(txn.errors[:party]).to include("must belong to your account")
    end

    it "rejects charge from a different tenancy" do
      other_unit = create(:rentable_unit, property: property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_charge = create(:charge, tenancy: other_tenancy, amount_cents: 50_000)

      txn = build(:security_deposit_transaction, :applied, security_deposit: security_deposit, charge: other_charge)
      expect(txn).not_to be_valid
      expect(txn.errors[:charge]).to include("must belong to the same tenancy as the security deposit")
    end

    it "rejects applied transaction when charge belongs to another user" do
      other_user = create(:user)
      other_prop = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_prop)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_charge = create(:charge, tenancy: other_tenancy, amount_cents: 50_000)

      txn = build(:security_deposit_transaction, :applied, security_deposit: security_deposit, charge: other_charge)
      expect(txn).not_to be_valid
      expect(txn.errors[:charge]).to include("must belong to your account")
    end

    it "rejects applied transaction when occurred_on precedes charge_date" do
      txn = build(
        :security_deposit_transaction,
        :applied,
        security_deposit: security_deposit,
        charge: charge,
        occurred_on: charge.charge_date - 5.days
      )
      expect(txn).not_to be_valid
      expect(txn.errors[:occurred_on]).to include("cannot precede the charge being settled (#{charge.charge_date})")
    end

    it "rejects occurred_on in the future" do
      txn = build(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party, occurred_on: Date.tomorrow)
      expect(txn).not_to be_valid
      expect(txn.errors[:occurred_on]).to include("cannot be in the future")
    end

    it "rejects non-positive amount" do
      txn = build(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party, amount_cents: 0)
      expect(txn).not_to be_valid
    end
  end

  describe "amount parsing helpers" do
    it "converts amount_cents to decimal and assigns from string/number" do
      txn = build(:security_deposit_transaction, amount_cents: 125_050)
      expect(txn.amount).to eq(1250.50)

      txn.amount = "500.25"
      expect(txn.amount_cents).to eq(50_025)

      txn.amount = 750
      expect(txn.amount_cents).to eq(75_000)

      txn.amount = ""
      expect(txn.amount_cents).to be_nil

      txn.amount = "bad"
      expect(txn.amount_cents).to eq(-1)
    end
  end

  describe "immutability and deletion restrictions" do
    let!(:posted_txn) do
      create(:security_deposit_transaction, :received, :posted, security_deposit: security_deposit, party: party, amount_cents: 100_000)
    end

    it "allows destroying unposted transaction but not posted transaction" do
      unposted = create(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party, posted_at: nil)
      expect { unposted.destroy }.to change(SecurityDepositTransaction, :count).by(-1)

      expect { posted_txn.destroy }.not_to change(SecurityDepositTransaction, :count)
      expect(posted_txn.errors[:base]).to include("Posted transactions cannot be deleted")
    end

    it "cannot modify financial attributes once posted" do
      expect(posted_txn.update(amount_cents: 150_000)).to be false
      expect(posted_txn.errors[:amount_cents]).to include("cannot be changed after transaction is posted")

      expect(posted_txn.update(occurred_on: 2.days.ago.to_date)).to be false
      expect(posted_txn.errors[:occurred_on]).to include("cannot be changed after transaction is posted")

      expect(posted_txn.update(party: create(:party, user: user))).to be false
      expect(posted_txn.errors[:party_id]).to include("cannot be changed after transaction is posted")

      expect(posted_txn.update(memo: "New memo")).to be false
      expect(posted_txn.errors[:memo]).to include("cannot be changed after transaction is posted")

      expect(posted_txn.update(external_reference: "REF123")).to be false
      expect(posted_txn.errors[:external_reference]).to include("cannot be changed after transaction is posted")
    end

    it "cannot directly set voided_at, superseded_by_id, or posted_at on initial creation" do
      txn_posted = build(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party, posted_at: Time.current)
      expect(txn_posted).not_to be_valid
      expect(txn_posted.errors[:posted_at]).to include("cannot be modified directly; posting is managed by the accounting service")

      txn_voided = build(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party, voided_at: Time.current)
      expect(txn_voided).not_to be_valid
      expect(txn_voided.errors[:voided_at]).to include("cannot be modified directly; use SecurityDepositTransactions::VoidService or SecurityDepositTransactions::CorrectService")

      txn_superseded = build(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party, superseded_by_id: 123)
      expect(txn_superseded).not_to be_valid
      expect(txn_superseded.errors[:superseded_by_id]).to include("cannot be modified directly; use SecurityDepositTransactions::CorrectService")
    end

    it "cannot directly set voided_at, superseded_by_id, or posted_at via ActiveRecord update on posted or unposted transactions" do
      expect(posted_txn.update(voided_at: Time.current)).to be false
      expect(posted_txn.errors[:voided_at]).to include("cannot be modified directly; use SecurityDepositTransactions::VoidService or SecurityDepositTransactions::CorrectService")

      rep = create(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party)
      expect(posted_txn.update(superseded_by_id: rep.id)).to be false
      expect(posted_txn.errors[:superseded_by_id]).to include("cannot be modified directly; use SecurityDepositTransactions::CorrectService")

      expect(posted_txn.update(posted_at: 1.day.from_now)).to be false
      expect(posted_txn.errors[:posted_at]).to include("cannot be modified directly; posting is managed by the accounting service")

      unposted = create(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party, posted_at: nil)
      expect(unposted.update(posted_at: Time.current)).to be false
      expect(unposted.errors[:posted_at]).to include("cannot be modified directly; posting is managed by the accounting service")
    end

    it "rejects applied transaction dated before the charge date" do
      future_charge = create(:charge, tenancy: tenancy, amount_cents: 50_000, charge_date: Date.new(2026, 1, 10))
      applied_txn = build(
        :security_deposit_transaction,
        :applied,
        security_deposit: security_deposit,
        charge: future_charge,
        occurred_on: Date.new(2026, 1, 5)
      )
      expect(applied_txn).not_to be_valid
      expect(applied_txn.errors[:occurred_on]).to include("cannot precede the charge being settled (2026-01-10)")

      applied_txn.occurred_on = Date.new(2026, 1, 10)
      expect(applied_txn).to be_valid

      applied_txn.occurred_on = Date.new(2026, 1, 15)
      expect(applied_txn).to be_valid
    end
  end

  describe "lifecycle predicates and association delegates" do
    it "reports posted?, voided?, superseded?, active? correctly and delegates associations" do
      txn = create(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party, posted_at: nil)
      expect(txn).not_to be_posted
      expect(txn).not_to be_active
      expect(txn.tenancy).to eq(tenancy)
      expect(txn.property).to eq(property)
      expect(txn.rentable_unit).to eq(unit)
      expect(txn.accounting_user).to eq(user)

      txn.update_columns(posted_at: Time.current)
      expect(txn).to be_posted
      expect(txn).to be_active

      txn.update_columns(voided_at: Time.current)
      expect(txn).to be_voided
      expect(txn).not_to be_active

      replacement = create(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party)
      txn.update_columns(superseded_by_id: replacement.id)
      expect(txn).to be_superseded
    end

    it "handles nil security_deposit on delegate methods" do
      orphan = SecurityDepositTransaction.new
      expect(orphan.tenancy).to be_nil
      expect(orphan.property).to be_nil
      expect(orphan.rentable_unit).to be_nil
      expect(orphan.accounting_user).to be_nil
    end
  end
end
