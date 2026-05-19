class CreateTenantPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :tenant_payments do |t|
      t.references :lease, null: false, foreign_key: true
      t.decimal :amount, null: false
      t.date :payment_date, null: false
      t.string :payment_method, null: false
      t.string :transaction_number

      t.timestamps
    end
  end
end
