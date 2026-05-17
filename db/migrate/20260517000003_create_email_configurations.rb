class CreateEmailConfigurations < ActiveRecord::Migration[8.1]
  def change
    create_table :email_configurations do |t|
      t.references :user,        null: false, foreign_key: true, index: { unique: true }
      t.string     :imap_server, null: false
      t.integer    :imap_port,   null: false, default: 993
      t.string     :username,    null: false
      t.string     :password,    null: false
      t.string     :mailbox,     null: false, default: "INBOX"
      t.boolean    :ssl,         null: false, default: true
      t.boolean    :enabled,     null: false, default: true
      t.datetime   :last_polled_at
      t.timestamps
    end
  end
end
