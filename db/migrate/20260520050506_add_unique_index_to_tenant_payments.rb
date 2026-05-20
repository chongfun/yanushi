class AddUniqueIndexToTenantPayments < ActiveRecord::Migration[8.1]
  def change
    add_index :tenant_payments, [ :payment_method, :transaction_number ], unique: true, where: "transaction_number IS NOT NULL"
  end
end
