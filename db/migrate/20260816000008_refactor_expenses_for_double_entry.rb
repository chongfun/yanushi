class RefactorExpensesForDoubleEntry < ActiveRecord::Migration[8.1]
  def up
    # Remove old columns
    remove_column :expenses, :amount, :decimal
    remove_column :expenses, :category, :string
    remove_column :expenses, :expense_date, :date

    # Add new domain & lifecycle columns
    add_reference :expenses, :rentable_unit, foreign_key: true, index: true
    add_column :expenses, :expense_kind, :string, null: false
    add_column :expenses, :amount_cents, :bigint, null: false
    add_column :expenses, :paid_on, :date, null: false
    add_column :expenses, :vendor_name, :string
    add_column :expenses, :external_reference, :string
    add_column :expenses, :posted_at, :datetime
    add_column :expenses, :voided_at, :datetime
    add_reference :expenses, :superseded_by, foreign_key: { to_table: :expenses }

    # Add check constraints
    add_check_constraint :expenses, "amount_cents > 0", name: "expenses_amount_cents_positive"
    add_check_constraint :expenses,
      "expense_kind IN ('advertising', 'auto_and_travel', 'cleaning_and_maintenance', 'commissions', 'insurance', 'legal_and_professional', 'management', 'mortgage_interest', 'other_interest', 'repairs', 'supplies', 'taxes', 'utilities', 'other')",
      name: "expenses_expense_kind_valid"

    # Add indexes
    add_index :expenses, [ :property_id, :paid_on ]
    add_index :expenses, :expense_kind
    add_index :expenses, :paid_on
    add_index :expenses, :voided_at
    add_index :expenses, :superseded_by_id, unique: true, where: "superseded_by_id IS NOT NULL", name: "index_expenses_on_superseded_by_id_unique"
  end

  def down
    remove_index :expenses, name: "index_expenses_on_superseded_by_id_unique", if_exists: true
    remove_index :expenses, :voided_at, if_exists: true
    remove_index :expenses, :paid_on, if_exists: true
    remove_index :expenses, :expense_kind, if_exists: true
    remove_index :expenses, [ :property_id, :paid_on ], if_exists: true

    remove_check_constraint :expenses, name: "expenses_expense_kind_valid"
    remove_check_constraint :expenses, name: "expenses_amount_cents_positive"

    remove_reference :expenses, :superseded_by
    remove_column :expenses, :voided_at
    remove_column :expenses, :posted_at
    remove_column :expenses, :external_reference
    remove_column :expenses, :vendor_name
    remove_column :expenses, :paid_on
    remove_column :expenses, :amount_cents
    remove_column :expenses, :expense_kind
    remove_reference :expenses, :rentable_unit

    add_column :expenses, :amount, :decimal, precision: 12, scale: 2
    add_column :expenses, :category, :string
    add_column :expenses, :expense_date, :date
  end
end
