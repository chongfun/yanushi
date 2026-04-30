class ChangeUtilityPaymentsAssociations < ActiveRecord::Migration[8.1]
  def change
    add_reference :utility_payments, :lease, null: false, foreign_key: true
    remove_column :utility_payments, :rental_property_id, :integer, null: false
    remove_column :utility_payments, :tenant_id, :integer, null: false
  end
end
