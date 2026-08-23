class CreatePropertyTaxProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :property_tax_profiles do |t|
      t.references :property, null: false, foreign_key: true
      t.integer :tax_year, null: false
      t.string :schedule_e_property_type, null: false
      t.string :other_description

      t.timestamps
    end

    add_index :property_tax_profiles, [ :property_id, :tax_year ], unique: true
    add_check_constraint :property_tax_profiles, "tax_year > 1900", name: "check_property_tax_profiles_tax_year_positive"
  end
end
