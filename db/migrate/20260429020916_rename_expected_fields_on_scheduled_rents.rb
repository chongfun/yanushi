class RenameExpectedFieldsOnScheduledRents < ActiveRecord::Migration[8.1]
  def change
    rename_column :scheduled_rents, :expected_amount, :amount
    rename_column :scheduled_rents, :expected_due_date, :due_date
  end
end
