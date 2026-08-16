require "rails_helper"

RSpec.describe Posting, type: :model do
  let(:user) { create(:user) }
  let(:journal_entry) { create(:journal_entry, user: user) }
  let(:account) { create(:account, user: user, key: "bank_cash", account_type: "asset") }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }

  describe "associations" do
    it { is_expected.to belong_to(:journal_entry) }
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:property).optional }
    it { is_expected.to belong_to(:rentable_unit).optional }
    it { is_expected.to belong_to(:tenancy).optional }
    it { is_expected.to belong_to(:party).optional }
  end

  describe "validations" do
    it "validates presence and nonzero integer amount_cents" do
      valid_debit = build(:posting, journal_entry: journal_entry, account: account, amount_cents: 10_000)
      expect(valid_debit).to be_valid
      expect(valid_debit.debit?).to be(true)
      expect(valid_debit.credit?).to be(false)
      expect(valid_debit.debit_amount).to eq(10_000)
      expect(valid_debit.credit_amount).to be_nil

      valid_credit = build(:posting, journal_entry: journal_entry, account: account, amount_cents: -10_000)
      expect(valid_credit).to be_valid
      expect(valid_credit.credit?).to be(true)
      expect(valid_credit.debit?).to be(false)
      expect(valid_credit.credit_amount).to eq(10_000)
      expect(valid_debit.credit_amount).to be_nil

      zero_posting = build(:posting, journal_entry: journal_entry, account: account, amount_cents: 0)
      expect(zero_posting).not_to be_valid
      expect(zero_posting.errors[:amount_cents]).to include("must be other than 0")

      nil_posting = build(:posting, journal_entry: journal_entry, account: account, amount_cents: nil)
      expect(nil_posting).not_to be_valid
    end

    it "validates that account belongs to journal_entry user" do
      other_user = create(:user)
      other_account = create(:account, user: other_user, key: "other_cash", account_type: "asset")

      posting = build(:posting, journal_entry: journal_entry, account: other_account)
      expect(posting).not_to be_valid
      expect(posting.errors[:account]).to include("must belong to the journal entry user")
    end

    it "validates that property belongs to journal_entry user" do
      other_user = create(:user)
      other_property = create(:property, user: other_user)

      posting = build(:posting, journal_entry: journal_entry, account: account, property: other_property)
      expect(posting).not_to be_valid
      expect(posting.errors[:property]).to include("must belong to the journal entry user")
    end

    it "validates that rentable_unit belongs to journal_entry user" do
      other_user = create(:user)
      other_unit = create(:rentable_unit, property: create(:property, user: other_user))

      posting = build(:posting, journal_entry: journal_entry, account: account, rentable_unit: other_unit)
      expect(posting).not_to be_valid
      expect(posting.errors[:rentable_unit]).to include("must belong to the journal entry user")
    end

    it "validates that tenancy belongs to journal_entry user" do
      other_user = create(:user)
      other_tenancy = create(:tenancy, rentable_unit: create(:rentable_unit, property: create(:property, user: other_user)))

      posting = build(:posting, journal_entry: journal_entry, account: account, tenancy: other_tenancy)
      expect(posting).not_to be_valid
      expect(posting.errors[:tenancy]).to include("must belong to the journal entry user")
    end

    it "validates that party belongs to journal_entry user" do
      other_user = create(:user)
      other_party = create(:party, user: other_user)

      posting = build(:posting, journal_entry: journal_entry, account: account, party: other_party)
      expect(posting).not_to be_valid
      expect(posting.errors[:party]).to include("must belong to the journal entry user")
    end

    it "permits party that belongs to user even if not a participant in the tenancy" do
      non_participant_party = create(:party, user: user)
      posting = build(:posting, journal_entry: journal_entry, account: account, tenancy: tenancy, party: non_participant_party)
      expect(posting).to be_valid
    end

    it "rejects contradictory unit and property dimensions" do
      other_property = create(:property, user: user)
      posting = build(:posting, journal_entry: journal_entry, account: account, property: other_property, rentable_unit: unit)
      expect(posting).not_to be_valid
      expect(posting.errors[:property]).to include("does not match rentable unit property")
    end

    it "rejects contradictory tenancy and unit dimensions" do
      other_unit = create(:rentable_unit, property: property, name: "Unit Other")
      posting = build(:posting, journal_entry: journal_entry, account: account, tenancy: tenancy, rentable_unit: other_unit)
      expect(posting).not_to be_valid
      expect(posting.errors[:rentable_unit]).to include("does not match tenancy rentable unit")
    end

    it "rejects contradictory tenancy and property dimensions" do
      other_property = create(:property, user: user)
      posting = build(:posting, journal_entry: journal_entry, account: account, tenancy: tenancy, property: other_property)
      expect(posting).not_to be_valid
      expect(posting.errors[:property]).to include("does not match tenancy property")
    end
  end

  describe "immutability" do
    let!(:persisted) { create(:posting, journal_entry: journal_entry, account: account, amount_cents: 25_000, memo: "Initial") }

    it "prevents updating attributes" do
      expect {
        persisted.update!(memo: "Changed memo")
      }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(persisted.reload.memo).to eq("Initial")
    end

    it "prevents deletion" do
      expect {
        persisted.destroy!
      }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(Posting.exists?(persisted.id)).to be(true)
    end
  end

  describe "#accounting_user" do
    let(:posting) { build(:posting, journal_entry: journal_entry, account: account, amount_cents: 10_000) }

    it "returns the user via journal_entry or account" do
      expect(posting.accounting_user).to eq(user)
    end

    it "returns user from account when journal_entry is absent" do
      orphan = build(:posting, journal_entry: nil, account: account, amount_cents: 10_000)
      expect(orphan.accounting_user).to eq(user)
    end

    it "returns nil when journal_entry and account are absent" do
      orphan = build(:posting, journal_entry: nil, account: nil, amount_cents: 10_000)
      expect(orphan.accounting_user).to be_nil
    end
  end
end
