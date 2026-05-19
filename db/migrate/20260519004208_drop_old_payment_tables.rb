class DropOldPaymentTables < ActiveRecord::Migration[8.1]
  def change
    drop_table :rent_payments do |t|
      t.decimal :amount
      t.date :payment_date
      t.string :payment_method
      t.integer :scheduled_rent_id, null: false
      t.string :transaction_number
      t.timestamps
    end

    drop_table :utility_payments do |t|
      t.decimal :amount
      t.bigint :expense_id
      t.integer :lease_id, null: false
      t.date :payment_date
      t.string :payment_method
      t.string :transaction_number
      t.timestamps
    end
  end
end
