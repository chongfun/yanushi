class CreateTenantAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :tenant_aliases do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string     :name,   null: false
      t.timestamps
    end

    add_index :tenant_aliases, [ :tenant_id, :name ], unique: true
  end
end
