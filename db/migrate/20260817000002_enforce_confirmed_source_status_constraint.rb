class EnforceConfirmedSourceStatusConstraint < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :imported_transactions, name: "imported_transactions_confirmed_source_check"
    add_check_constraint :imported_transactions,
                         "(status = 'confirmed' AND confirmed_source_type IS NOT NULL AND confirmed_source_id IS NOT NULL) OR (status != 'confirmed' AND confirmed_source_type IS NULL AND confirmed_source_id IS NULL)",
                         name: "imported_transactions_confirmed_source_check"
  end
end
