class AddReportingIndexesToPostingsAndJournalEntries < ActiveRecord::Migration[8.1]
  def change
    add_index :postings, %i[property_id journal_entry_id], name: "index_postings_on_property_id_and_journal_entry_id"
    add_index :postings, %i[tenancy_id journal_entry_id], name: "index_postings_on_tenancy_id_and_journal_entry_id"
    add_index :postings, %i[account_id journal_entry_id], name: "index_postings_on_account_id_and_journal_entry_id"
    add_index :journal_entries, %i[user_id occurred_on id], name: "index_journal_entries_on_user_id_and_occurred_on_and_id"
  end
end
