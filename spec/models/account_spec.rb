require "rails_helper"

RSpec.describe Account, type: :model do
  let(:user) { create(:user) }
  let(:account) { create(:account, user: user, key: "cash_main", name: "Cash Main", account_type: "asset") }

  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:postings).dependent(:restrict_with_error) }
  end

  describe "validations" do
    subject { build(:account, user: user) }

    it { is_expected.to validate_presence_of(:key) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:account_type) }

    it "validates uniqueness of key scoped to user" do
      create(:account, user: user, key: "operating_cash")
      dup = build(:account, user: user, key: "operating_cash")
      expect(dup).not_to be_valid
      expect(dup.errors[:key]).to include("has already been taken")
    end

    it "permits the same key for different users" do
      other_user = create(:user)
      create(:account, user: user, key: "operating_cash")
      other_account = build(:account, user: other_user, key: "operating_cash")
      expect(other_account).to be_valid
    end

    it "validates key format allows lowercase letters, numbers, and underscores" do
      valid_account = build(:account, user: user, key: "valid_key_123")
      expect(valid_account).to be_valid

      invalid_account = build(:account, user: user, key: "Invalid-Key!")
      expect(invalid_account).not_to be_valid
      expect(invalid_account.errors[:key]).to include("must contain only lowercase letters, numbers, and underscores")
    end

    it "accepts all valid account types" do
      Account::ACCOUNT_TYPES.each do |type|
        acc = build(:account, user: user, key: "type_#{type}", account_type: type)
        expect(acc).to be_valid
      end
    end

    it "rejects invalid account types" do
      acc = build(:account, user: user, account_type: "invalid_type")
      expect(acc).not_to be_valid
      expect(acc.errors[:account_type]).to be_present
    end
  end

  describe "normalizations" do
    it "normalizes key and name" do
      acc = create(:account, user: user, key: "  CUSTOM_CASH_1  ", name: "  My Cash Account  ")
      expect(acc.key).to eq("custom_cash_1")
      expect(acc.name).to eq("My Cash Account")
    end
  end

  describe "immutability on update" do
    let!(:persisted_account) { create(:account, user: user, key: "test_immutability", account_type: "asset") }

    it "prevents changing user_id" do
      other_user = create(:user)
      persisted_account.user = other_user
      expect(persisted_account).not_to be_valid
      expect(persisted_account.errors[:user_id]).to include("cannot be changed")
    end

    it "prevents changing key" do
      persisted_account.key = "new_key"
      expect(persisted_account).not_to be_valid
      expect(persisted_account.errors[:key]).to include("cannot be changed")
    end

    it "prevents changing account_type" do
      persisted_account.account_type = "liability"
      expect(persisted_account).not_to be_valid
      expect(persisted_account.errors[:account_type]).to include("cannot be changed")
    end

    it "allows changing name and active" do
      persisted_account.update!(name: "Updated Name", active: false)
      expect(persisted_account.reload.name).to eq("Updated Name")
      expect(persisted_account.active).to be(false)
    end
  end

  describe "deletion protection" do
    let(:journal_entry) { create(:journal_entry, user: user) }

    it "cannot be destroyed when postings exist" do
      create(:posting, journal_entry: journal_entry, account: account, amount_cents: 5000)

      expect {
        account.destroy
      }.not_to change(Account, :count)
      expect(account.errors[:base]).to be_present
    end
  end

  describe "#accounting_user" do
    it "returns the account owner" do
      expect(account.accounting_user).to eq(user)
    end
  end
end
