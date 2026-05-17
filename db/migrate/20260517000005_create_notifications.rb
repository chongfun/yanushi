class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :user,          null: false, foreign_key: true
      t.string     :title,         null: false
      t.text       :message
      t.string     :notification_type, null: false
      t.boolean    :read,          null: false, default: false
      t.references :payment_email, null: true, foreign_key: true
      t.timestamps
    end
  end
end
