class CreatePaymentReceiptIngestions < ActiveRecord::Migration[8.1]
  def change
    create_table :payment_receipt_ingestions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :tenant, null: true, foreign_key: true
      t.references :lease, null: true, foreign_key: true
      t.references :tenant_payment, null: true, foreign_key: true
      t.string :source, null: false
      t.string :receipt_type
      t.string :status, null: false, default: "pending"
      t.string :payer_name
      t.string :payer_username
      t.decimal :amount, precision: 12, scale: 2
      t.date :payment_date
      t.string :payment_method
      t.string :transaction_number
      t.text :raw_text
      t.text :error_message
      t.binary :attachment_file
      t.string :attachment_filename
      t.string :attachment_content_type

      t.timestamps
    end
  end
end
