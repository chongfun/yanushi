class CreatePaymentEmails < ActiveRecord::Migration[8.1]
  def change
    create_table :payment_emails do |t|
      t.references :user,            null: false, foreign_key: true
      t.string     :message_id,      null: false
      t.string     :sender_name
      t.decimal    :amount
      t.date       :payment_date
      t.string     :transaction_id
      t.string     :provider
      t.string     :status,          null: false, default: "pending"
      t.string     :error_message
      t.references :tenant_payment,  null: true, foreign_key: true
      t.text       :raw_body
      t.timestamps
    end

    add_index :payment_emails, [ :user_id, :message_id ], unique: true
  end
end
