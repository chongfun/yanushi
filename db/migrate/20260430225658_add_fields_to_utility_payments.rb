class AddFieldsToUtilityPayments < ActiveRecord::Migration[8.1]
  def change
    add_column :utility_payments, :payment_method, :string
    add_column :utility_payments, :transaction_number, :string
  end
end
