class DropTenantCharges < ActiveRecord::Migration[8.1]
  def change
    drop_table :tenant_charges do |t|
      t.references :tenancy, null: false, foreign_key: true
      t.references :expense, null: false, foreign_key: true
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.date :charge_date, null: false
      t.text :description

      t.timestamps
    end
  end
end
