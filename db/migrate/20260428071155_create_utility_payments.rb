class CreateUtilityPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :utility_payments do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :rental_property, null: false, foreign_key: true
      t.decimal :amount
      t.date :payment_date

      t.timestamps
    end
  end
end
