class AddTransactionNumberToRentPayments < ActiveRecord::Migration[8.1]
  def change
    add_column :rent_payments, :transaction_number, :string
  end
end
