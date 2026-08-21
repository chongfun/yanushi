class DropTenantPayments < ActiveRecord::Migration[8.1]
  def change
    drop_table :tenant_payments do |t|
      t.references :tenancy, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :payment_date, null: false
      t.string :payment_method, null: false
      t.string :transaction_number

      t.timestamps
    end
  end
end
