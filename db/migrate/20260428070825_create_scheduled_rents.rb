class CreateScheduledRents < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_rents do |t|
      t.references :lease, null: false, foreign_key: true
      t.decimal :expected_amount
      t.date :expected_due_date

      t.timestamps
    end
  end
end
