class AddLockVersionToImportedTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :imported_transactions, :lock_version, :integer, default: 0, null: false
  end
end
