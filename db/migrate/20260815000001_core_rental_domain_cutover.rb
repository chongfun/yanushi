class CoreRentalDomainCutover < ActiveRecord::Migration[8.1]
  def up
    # 1. Drop obsolete foreign keys first to allow clean table/column renames
    remove_foreign_key :expenses, :rental_properties if foreign_key_exists?(:expenses, :rental_properties)
    remove_foreign_key :leases, :rental_properties if foreign_key_exists?(:leases, :rental_properties)
    remove_foreign_key :lease_tenants, :leases if foreign_key_exists?(:lease_tenants, :leases)
    remove_foreign_key :lease_tenants, :tenants if foreign_key_exists?(:lease_tenants, :tenants)
    remove_foreign_key :tenant_aliases, :tenants if foreign_key_exists?(:tenant_aliases, :tenants)
    remove_foreign_key :scheduled_rents, :leases if foreign_key_exists?(:scheduled_rents, :leases)
    remove_foreign_key :tenant_payments, :leases if foreign_key_exists?(:tenant_payments, :leases)
    remove_foreign_key :tenant_charges, :leases if foreign_key_exists?(:tenant_charges, :leases)
    remove_foreign_key :payment_ingestions, :leases if foreign_key_exists?(:payment_ingestions, :leases)
    remove_foreign_key :payment_ingestions, :tenants if foreign_key_exists?(:payment_ingestions, :tenants)

    # 2. Rename core tables
    rename_table :rental_properties, :properties
    rename_table :tenants, :parties
    rename_table :tenant_aliases, :party_aliases
    rename_table :leases, :tenancies
    rename_table :lease_tenants, :tenancy_parties

    # 3. Reshape properties
    remove_column :properties, :property_type, :integer
    add_column :properties, :asset_type, :string, null: false, default: "single_family"
    change_column_default :properties, :asset_type, from: "single_family", to: nil
    change_column_null :properties, :address, false

    # 4. Create rentable_units
    create_table :rentable_units do |t|
      t.bigint :property_id, null: false
      t.string :name, null: false
      t.string :unit_identifier
      t.integer :square_footage
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :rentable_units, :property_id
    add_index :rentable_units, "property_id, lower(unit_identifier)",
              name: "index_rentable_units_on_property_id_and_lower_identifier",
              unique: true,
              where: "unit_identifier IS NOT NULL"
    add_foreign_key :rentable_units, :properties

    # 5. Reshape parties
    rename_column :parties, :name, :display_name
    change_column_null :parties, :display_name, false
    add_column :parties, :party_type, :string, null: false, default: "individual"
    change_column_default :parties, :party_type, from: "individual", to: nil

    # 6. Reshape party_aliases
    rename_column :party_aliases, :tenant_id, :party_id
    add_foreign_key :party_aliases, :parties

    # 7. Reshape tenancies
    remove_column :tenancies, :rental_property_id, :integer
    remove_column :tenancies, :annual_rental_amount, :decimal
    remove_column :tenancies, :security_deposit, :decimal
    remove_column :tenancies, :lease_type, :integer

    add_column :tenancies, :rentable_unit_id, :bigint, null: false
    add_column :tenancies, :agreement_type, :string, null: false, default: "fixed_term"
    change_column_default :tenancies, :agreement_type, from: "fixed_term", to: nil
    change_column_null :tenancies, :commencement_date, false
    change_column_null :tenancies, :late_period_days, false, 0
    change_column_default :tenancies, :late_period_days, from: nil, to: 0

    add_index :tenancies, :rentable_unit_id
    add_foreign_key :tenancies, :rentable_units

    # 8. Reshape tenancy_parties
    rename_column :tenancy_parties, :lease_id, :tenancy_id
    rename_column :tenancy_parties, :tenant_id, :party_id
    add_column :tenancy_parties, :role, :string, null: false, default: "tenant"
    change_column_default :tenancy_parties, :role, from: "tenant", to: nil
    add_column :tenancy_parties, :effective_from, :date, null: false, default: -> { "CURRENT_DATE" }
    change_column_default :tenancy_parties, :effective_from, from: -> { "CURRENT_DATE" }, to: nil
    add_column :tenancy_parties, :effective_until, :date

    add_index :tenancy_parties, %i[tenancy_id party_id role effective_from],
              name: "idx_tenancy_parties_exact_dup",
              unique: true
    add_foreign_key :tenancy_parties, :tenancies
    add_foreign_key :tenancy_parties, :parties

    # 9. Create rent_terms
    create_table :rent_terms do |t|
      t.bigint :tenancy_id, null: false
      t.bigint :amount_cents, null: false
      t.string :frequency, null: false, default: "monthly"
      t.integer :due_day, null: false, default: 1
      t.date :effective_from, null: false
      t.date :effective_until
      t.timestamps
    end
    add_index :rent_terms, :tenancy_id
    add_index :rent_terms, %i[tenancy_id effective_from], unique: true
    add_foreign_key :rent_terms, :tenancies

    # 10. Retarget surviving financial tables
    rename_column :expenses, :rental_property_id, :property_id
    add_foreign_key :expenses, :properties

    rename_column :scheduled_rents, :lease_id, :tenancy_id
    add_foreign_key :scheduled_rents, :tenancies

    rename_column :tenant_payments, :lease_id, :tenancy_id
    add_foreign_key :tenant_payments, :tenancies

    rename_column :tenant_charges, :lease_id, :tenancy_id
    add_foreign_key :tenant_charges, :tenancies

    rename_column :payment_ingestions, :lease_id, :tenancy_id
    rename_column :payment_ingestions, :tenant_id, :party_id
    add_foreign_key :payment_ingestions, :tenancies
    add_foreign_key :payment_ingestions, :parties
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Milestone 1 cutover is irreversible without data backfill"
  end
end
