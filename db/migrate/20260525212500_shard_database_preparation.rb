class ShardDatabasePreparation < ActiveRecord::Migration[8.1]
  def change
    # 1. Add shard column to users
    add_column :users, :shard, :string

    # 2. Remove foreign keys to users from the sharded tables on primary
    remove_foreign_key :payment_documents, :users if foreign_key_exists?(:payment_documents, :users)
    remove_foreign_key :payment_ingestions, :users if foreign_key_exists?(:payment_ingestions, :users)
    remove_foreign_key :rental_properties, :users if foreign_key_exists?(:rental_properties, :users)
    remove_foreign_key :tenant_payments, :users if foreign_key_exists?(:tenant_payments, :users)
    remove_foreign_key :tenants, :users if foreign_key_exists?(:tenants, :users)

    # 3. Drop sharded tables from primary (they will only live in shards)
    drop_table :tenant_aliases, if_exists: true
    drop_table :tenant_charges, if_exists: true
    drop_table :payment_ingestions, if_exists: true
    drop_table :payment_documents, if_exists: true
    drop_table :tenant_payments, if_exists: true
    drop_table :scheduled_rents, if_exists: true
    drop_table :lease_tenants, if_exists: true
    drop_table :leases, if_exists: true
    drop_table :expenses, if_exists: true
    drop_table :tenants, if_exists: true
    drop_table :rental_properties, if_exists: true
  end
end
