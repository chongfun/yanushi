class CreateTenantAliases < ActiveRecord::Migration[8.1]
  def up
    create_table :tenant_aliases do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :alias_name, null: false

      t.timestamps
    end

    execute "CREATE UNIQUE INDEX index_tenant_aliases_on_tenant_id_and_lower_alias_name ON tenant_aliases (tenant_id, lower(alias_name))"
  end

  def down
    drop_table :tenant_aliases
  end
end
