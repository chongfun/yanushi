class CreateExpenses < ActiveRecord::Migration[8.1]
  def change
    create_table :expenses do |t|
      t.references :rental_property, null: false, foreign_key: true
      t.string :category
      t.decimal :amount
      t.date :expense_date
      t.string :description

      t.timestamps
    end
  end
end
