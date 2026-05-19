class ChangeDecimalFieldsPrecisionAndScale < ActiveRecord::Migration[8.1]
  def change
    change_column :expenses, :amount, :decimal, precision: 12, scale: 2
    change_column :leases, :annual_rental_amount, :decimal, precision: 12, scale: 2
    change_column :leases, :security_deposit, :decimal, precision: 12, scale: 2
    change_column :scheduled_rents, :amount, :decimal, precision: 12, scale: 2
    change_column :tenant_charges, :amount, :decimal, precision: 12, scale: 2, null: false
    change_column :tenant_payments, :amount, :decimal, precision: 12, scale: 2, null: false
  end
end
