class CreateTenantCharges < ActiveRecord::Migration[8.1]
  def change
    create_table :tenant_charges do |t|
      t.references :lease, null: false, foreign_key: true
      t.references :expense, null: false, foreign_key: true
      t.decimal :amount, null: false
      t.date :charge_date, null: false
      t.string :description

      t.timestamps
    end
  end
end
