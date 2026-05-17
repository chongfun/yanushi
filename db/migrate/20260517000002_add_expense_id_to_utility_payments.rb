class AddExpenseIdToUtilityPayments < ActiveRecord::Migration[8.1]
  def change
    add_reference :utility_payments, :expense, null: true, foreign_key: true
  end
end
