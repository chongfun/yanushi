class CreatePropertyTaxReviewResolutions < ActiveRecord::Migration[8.1]
  def change
    create_table :property_tax_review_resolutions do |t|
      t.references :property, null: false, foreign_key: true
      t.integer :tax_year, null: false
      t.references :journal_entry, null: false, foreign_key: true
      t.string :treatment, null: false
      t.text :notes

      t.timestamps
    end

    add_index :property_tax_review_resolutions,
              [ :property_id, :tax_year, :journal_entry_id ],
              unique: true,
              name: "idx_tax_review_resolutions_on_prop_year_entry"
  end
end
