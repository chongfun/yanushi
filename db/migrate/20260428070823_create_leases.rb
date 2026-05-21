class CreateLeases < ActiveRecord::Migration[8.1]
  def change
    create_table :leases do |t|
      t.references :rental_property, null: false, foreign_key: true
      t.integer :lease_type
      t.date :commencement_date
      t.date :termination_date
      t.decimal :annual_rental_amount
      t.integer :late_period_days

      t.timestamps
    end
  end
end
