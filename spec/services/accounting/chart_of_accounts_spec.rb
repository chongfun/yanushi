require "rails_helper"

RSpec.describe Accounting::ChartOfAccounts do
  let!(:user) { create(:user) }

  describe "user provisioning on create" do
    it "automatically provisions all 17 system accounts on user creation" do
      expect(user.accounts.count).to eq(17)

      described_class::SYSTEM_ACCOUNTS.each do |defn|
        acc = user.accounts.find_by(key: defn[:key])
        expect(acc).to be_present
        expect(acc.name).to eq(defn[:name])
        expect(acc.account_type).to eq(defn[:account_type])
        expect(acc.active).to be(true)
      end
    end

    it "provisions charts independently for different users" do
      other_user = create(:user)
      expect(user.accounts.count).to eq(17)
      expect(other_user.accounts.count).to eq(17)

      cash1 = user.accounts.find_by(key: "cash")
      cash2 = other_user.accounts.find_by(key: "cash")
      expect(cash1.id).not_to eq(cash2.id)
    end

    it "rolls back user creation if chart provisioning fails" do
      allow(described_class).to receive(:ensure_for).and_raise(StandardError, "Provisioning exploded")

      expect {
        User.create!(email: "rollback-test@example.com", password: "password")
      }.to raise_error(StandardError, "Provisioning exploded")

      expect(User.find_by(email: "rollback-test@example.com")).to be_nil
    end
  end

  describe ".ensure_for" do
    it "is idempotent and creates no duplicate accounts on repeated calls" do
      expect {
        described_class.ensure_for(user)
      }.not_to change(Account, :count)
    end

    it "restores missing system accounts without modifying existing ones" do
      cash_account = user.accounts.find_by(key: "cash")
      cash_account.postings.destroy_all
      cash_account.delete

      expect(user.accounts.find_by(key: "cash")).to be_nil

      expect {
        described_class.ensure_for(user)
      }.to change { Account.where(user: user).count }.by(1)

      restored_cash = user.accounts.find_by(key: "cash")
      expect(restored_cash).to be_present
      expect(restored_cash.name).to eq("Cash")
      expect(restored_cash.account_type).to eq("asset")
    end

    it "raises AccountTypeMismatchError if an existing key has the wrong account type" do
      cash_account = user.accounts.find_by(key: "cash")
      cash_account.update_columns(account_type: "liability")

      expect {
        described_class.ensure_for(user)
      }.to raise_error(Accounting::ChartOfAccounts::AccountTypeMismatchError, /Account 'cash' for user #{user.id} has type 'liability', expected 'asset'/)
    end
  end
end
