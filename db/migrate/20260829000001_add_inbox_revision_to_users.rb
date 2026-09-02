class AddInboxRevisionToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :inbox_revision, :bigint, default: 0, null: false
  end
end
