class RemovePaidFromScheduledRents < ActiveRecord::Migration[8.1]
  def change
    remove_column :scheduled_rents, :paid, :boolean, default: false, null: false
  end
end
