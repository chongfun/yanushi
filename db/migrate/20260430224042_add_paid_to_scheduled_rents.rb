class AddPaidToScheduledRents < ActiveRecord::Migration[8.1]
  def change
    add_column :scheduled_rents, :paid, :boolean, default: false, null: false

    # Backfill: mark any scheduled_rent that already has a rent_payment as paid
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE scheduled_rents
          SET paid = TRUE
          WHERE id IN (SELECT scheduled_rent_id FROM rent_payments)
        SQL
      end
    end
  end
end
