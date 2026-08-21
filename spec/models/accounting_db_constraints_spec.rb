require "rails_helper"

RSpec.describe "Accounting Database Constraints", type: :model do
  let!(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:cash_account) { user.accounts.find_by!(key: "cash") }

  let!(:journal_entry) do
    create(:journal_entry,
      user: user,
      source_type: "Expense",
      source_id: 999,
      event_type: "expense_posted",
      occurred_on: Date.current,
      posted_at: Time.current
    )
  end

  describe "accounts check constraint" do
    it "enforces account_type check constraint at PostgreSQL level" do
      expect {
        ActiveRecord::Base.connection.execute(
          "INSERT INTO accounts (user_id, key, name, account_type, active, created_at, updated_at) " \
          "VALUES (#{user.id}, 'invalid_raw_key', 'Invalid Account', 'bogus_type', true, NOW(), NOW())"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /check_accounts_account_type/)
    end
  end

  describe "postings check constraint" do
    it "enforces amount_cents <> 0 at PostgreSQL level" do
      expect {
        ActiveRecord::Base.connection.execute(
          "INSERT INTO postings (journal_entry_id, account_id, amount_cents, created_at) " \
          "VALUES (#{journal_entry.id}, #{cash_account.id}, 0, NOW())"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /check_postings_amount_cents_nonzero/)
    end
  end

  describe "journal_entries check constraint" do
    it "enforces source_id > 0 at PostgreSQL level" do
      expect {
        ActiveRecord::Base.connection.execute(
          "INSERT INTO journal_entries (user_id, source_type, source_id, event_type, occurred_on, posted_at, created_at) " \
          "VALUES (#{user.id}, 'Expense', 0, 'test_event', CURRENT_DATE, NOW(), NOW())"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /check_journal_entries_source_id_positive/)
    end
  end

  describe "journal_entries unique index constraints" do
    it "enforces unique source-event tuple at PostgreSQL level" do
      expect {
        ActiveRecord::Base.connection.execute(
          "INSERT INTO journal_entries (user_id, source_type, source_id, event_type, occurred_on, posted_at, created_at) " \
          "VALUES (#{user.id}, 'Expense', 999, 'expense_posted', CURRENT_DATE, NOW(), NOW())"
        )
      }.to raise_error(ActiveRecord::RecordNotUnique, /idx_journal_entries_source_event/)
    end

    it "enforces single reversal_of_id constraint at PostgreSQL level" do
      reversal1 = create(:journal_entry,
        user: user,
        source_type: "JournalEntry",
        source_id: journal_entry.id,
        event_type: "reversal",
        reversal_of: journal_entry
      )

      expect {
        ActiveRecord::Base.connection.execute(
          "INSERT INTO journal_entries (user_id, source_type, source_id, event_type, occurred_on, posted_at, reversal_of_id, created_at) " \
          "VALUES (#{user.id}, 'JournalEntry', #{journal_entry.id}, 'reversal_dup', CURRENT_DATE, NOW(), #{journal_entry.id}, NOW())"
        )
      }.to raise_error(ActiveRecord::RecordNotUnique, /idx_journal_entries_single_reversal/)
    end
  end

  describe "dimension lifecycle deletion protection" do
    let!(:posting) do
      create(:posting,
        journal_entry: journal_entry,
        account: cash_account,
        amount_cents: 10_000,
        property: property,
        rentable_unit: unit,
        tenancy: tenancy,
        party: party
      )
    end

    it "prevents deleting Property when referenced by postings" do
      expect {
        property.destroy
      }.not_to change(Property, :count)
      expect(property.destroyed?).to be(false)

      prop_direct = create(:property, user: user)
      create(:posting, journal_entry: journal_entry, account: cash_account, property: prop_direct)
      expect {
        prop_direct.destroy
      }.not_to change(Property, :count)
      expect(prop_direct.errors[:base]).to be_present
    end

    it "prevents deleting RentableUnit when referenced by postings" do
      expect {
        unit.destroy
      }.not_to change(RentableUnit, :count)
      expect(unit.errors[:base]).to be_present
    end

    it "prevents deleting Tenancy when referenced by postings" do
      expect {
        tenancy.destroy
      }.not_to change(Tenancy, :count)
      expect(tenancy.errors[:base]).to be_present
      expect(tenancy.financial_history?).to be(true)
    end

    it "prevents deleting Party when referenced by postings" do
      expect {
        party.destroy
      }.not_to change(Party, :count)
      expect(party.errors[:base]).to be_present
    end
  end
end
