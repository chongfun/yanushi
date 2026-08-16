class CreateAccountingFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.bigint :user_id, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.string :account_type, null: false
      t.boolean :active, default: true, null: false

      t.timestamps
    end

    add_index :accounts, :user_id
    add_index :accounts, %i[user_id key], unique: true
    add_foreign_key :accounts, :users
    add_check_constraint :accounts,
                         "account_type IN ('asset', 'liability', 'equity', 'income', 'expense')",
                         name: "check_accounts_account_type"

    create_table :journal_entries do |t|
      t.bigint :user_id, null: false
      t.string :source_type, null: false
      t.bigint :source_id, null: false
      t.string :event_type, null: false
      t.date :occurred_on, null: false
      t.string :description
      t.datetime :posted_at, null: false
      t.bigint :reversal_of_id

      t.datetime :created_at, null: false
    end

    add_index :journal_entries, :user_id
    add_index :journal_entries, :occurred_on
    add_index :journal_entries, %i[user_id source_type source_id event_type],
              unique: true,
              name: "idx_journal_entries_source_event"
    add_index :journal_entries, :reversal_of_id,
              unique: true,
              where: "reversal_of_id IS NOT NULL",
              name: "idx_journal_entries_single_reversal"
    add_foreign_key :journal_entries, :users
    add_foreign_key :journal_entries, :journal_entries, column: :reversal_of_id
    add_check_constraint :journal_entries,
                         "source_id > 0",
                         name: "check_journal_entries_source_id_positive"

    create_table :postings do |t|
      t.bigint :journal_entry_id, null: false
      t.bigint :account_id, null: false
      t.bigint :amount_cents, null: false

      t.bigint :property_id
      t.bigint :rentable_unit_id
      t.bigint :tenancy_id
      t.bigint :party_id

      t.string :memo

      t.datetime :created_at, null: false
    end

    add_index :postings, :journal_entry_id
    add_index :postings, :account_id
    add_index :postings, :property_id
    add_index :postings, :rentable_unit_id
    add_index :postings, :tenancy_id
    add_index :postings, :party_id
    add_index :postings, %i[account_id property_id]
    add_index :postings, %i[account_id tenancy_id]

    add_foreign_key :postings, :journal_entries
    add_foreign_key :postings, :accounts
    add_foreign_key :postings, :properties
    add_foreign_key :postings, :rentable_units
    add_foreign_key :postings, :tenancies
    add_foreign_key :postings, :parties
    add_check_constraint :postings,
                         "amount_cents <> 0",
                         name: "check_postings_amount_cents_nonzero"
  end
end
