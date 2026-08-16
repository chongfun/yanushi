class CreateReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :receipts do |t|
      t.references :user, null: false, foreign_key: true
      t.references :tenancy, null: false, foreign_key: true
      t.references :payer_party, null: false, foreign_key: { to_table: :parties }
      t.bigint :amount_cents, null: false
      t.date :received_on, null: false
      t.string :payment_method, null: false
      t.string :external_reference
      t.text :memo
      t.timestamptz :posted_at
      t.timestamptz :voided_at
      t.references :superseded_by, foreign_key: { to_table: :receipts }

      t.timestamps
    end

    add_check_constraint :receipts, "amount_cents > 0", name: "receipts_amount_cents_positive"
    add_index :receipts, :received_on
    add_index :receipts, :voided_at
    add_index :receipts, :superseded_by_id, unique: true, where: "superseded_by_id IS NOT NULL", name: "index_receipts_on_superseded_by_id_unique"
    add_index :receipts, %i[user_id payment_method external_reference],
              unique: true,
              where: "external_reference IS NOT NULL AND voided_at IS NULL",
              name: "index_receipts_on_user_method_external_ref_active"
  end
end
