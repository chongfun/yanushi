require "rails_helper"

RSpec.describe Accounting::ChartOfAccounts do
  let!(:user) { create(:user) }

  describe "user provisioning on create" do
    it "automatically provisions all system accounts on user creation" do
      expect(user.accounts.count).to eq(described_class::SYSTEM_ACCOUNTS.count)

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
      expect(user.accounts.count).to eq(described_class::SYSTEM_ACCOUNTS.count)
      expect(other_user.accounts.count).to eq(described_class::SYSTEM_ACCOUNTS.count)

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

    it "provisions newly-added system accounts for an existing user missing them" do
      # Simulate existing user missing specific system accounts
      system_keys = %w[expense_auto_travel expense_commissions expense_mortgage_interest expense_other_interest]
      user.accounts.where(key: system_keys).each do |acct|
        acct.postings.destroy_all
        acct.delete
      end
      expect(user.accounts.reload.where(key: system_keys).count).to eq(0)

      # Run ensure_for
      described_class.ensure_for(user)

      # Accounts now exist and are active
      system_keys.each do |key|
        acct = user.accounts.reload.find_by(key: key)
        expect(acct).to be_present, "Expected account '#{key}' to be provisioned"
        expect(acct.active).to be(true)
      end

      # Can successfully post an expense using each new category
      property = create(:property, user: user)
      %w[auto_and_travel commissions mortgage_interest other_interest].each do |kind|
        result = Expenses::CreateService.call(
          property: property,
          expense_kind: kind,
          paid_on: Date.current,
          amount_cents: 5_000
        )
        expect(result).to be_success, "Expected posting '#{kind}' to succeed, got: #{result.failure&.error rescue 'unknown'}"
      end
    end
  end
end
