class CreateRentPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :rent_payments do |t|
      t.references :scheduled_rent, null: false, foreign_key: true
      t.date :payment_date
      t.decimal :amount
      t.string :payment_method

      t.timestamps
    end
  end
end
