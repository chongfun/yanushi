class CreateRentalProperties < ActiveRecord::Migration[8.1]
  def change
    create_table :rental_properties do |t|
      t.references :user, null: false, foreign_key: true
      t.string :address
      t.integer :property_type
      t.integer :square_footage

      t.timestamps
    end
  end
end
