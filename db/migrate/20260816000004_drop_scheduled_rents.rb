class DropScheduledRents < ActiveRecord::Migration[8.1]
  def change
    drop_table :scheduled_rents do |t|
      t.references :tenancy, null: false, foreign_key: true
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.date :due_date, null: false

      t.timestamps
    end
  end
end
