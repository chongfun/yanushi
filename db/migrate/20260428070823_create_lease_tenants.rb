class CreateLeaseTenants < ActiveRecord::Migration[8.1]
  def change
    create_table :lease_tenants do |t|
      t.references :lease, null: false, foreign_key: true
      t.references :tenant, null: false, foreign_key: true

      t.timestamps
    end
  end
end
