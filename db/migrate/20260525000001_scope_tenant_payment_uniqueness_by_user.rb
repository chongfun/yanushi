class ScopeTenantPaymentUniquenessByUser < ActiveRecord::Migration[8.1]
  OLD_INDEX_NAME = "index_tenant_payments_on_payment_method_and_transaction_number"
  NEW_INDEX_NAME = "index_tenant_payments_on_user_payment_method_transaction_number"

  def up
    add_reference :tenant_payments, :user, null: true, foreign_key: true

    execute <<~SQL.squish
      UPDATE tenant_payments
      SET user_id = rental_properties.user_id
      FROM leases
      INNER JOIN rental_properties ON rental_properties.id = leases.rental_property_id
      WHERE tenant_payments.lease_id = leases.id
    SQL

    change_column_null :tenant_payments, :user_id, false

    remove_index :tenant_payments, name: OLD_INDEX_NAME
    add_index :tenant_payments,
      [ :user_id, :payment_method, :transaction_number ],
      unique: true,
      where: "transaction_number IS NOT NULL",
      name: NEW_INDEX_NAME
  end

  def down
    remove_index :tenant_payments, name: NEW_INDEX_NAME
    add_index :tenant_payments,
      [ :payment_method, :transaction_number ],
      unique: true,
      where: "transaction_number IS NOT NULL",
      name: OLD_INDEX_NAME

    remove_reference :tenant_payments, :user, foreign_key: true
  end
end
