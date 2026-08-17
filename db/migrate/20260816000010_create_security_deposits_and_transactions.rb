class CreateSecurityDepositsAndTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :security_deposits do |t|
      t.references :tenancy, null: false, foreign_key: true, index: { unique: true }
      t.bigint :required_amount_cents, null: false
      t.date :due_on, null: false

      t.timestamps
    end

    add_check_constraint :security_deposits, "required_amount_cents > 0", name: "security_deposits_required_amount_cents_positive"

    create_table :security_deposit_transactions do |t|
      t.references :security_deposit, null: false, foreign_key: true
      t.string :transaction_kind, null: false
      t.bigint :amount_cents, null: false
      t.date :occurred_on, null: false

      t.references :party, foreign_key: true
      t.references :charge, foreign_key: true
      t.string :external_reference
      t.text :memo

      t.datetime :posted_at
      t.datetime :voided_at
      t.references :superseded_by, foreign_key: { to_table: :security_deposit_transactions }

      t.timestamps
    end

    add_check_constraint :security_deposit_transactions, "amount_cents > 0", name: "security_deposit_transactions_amount_cents_positive"
    add_check_constraint :security_deposit_transactions, "transaction_kind IN ('received', 'refunded', 'applied')", name: "security_deposit_transactions_kind_check"

    add_index :security_deposit_transactions, [ :security_deposit_id, :transaction_kind ], name: "index_sdt_on_deposit_and_kind"
    add_index :security_deposit_transactions, :occurred_on
    add_index :security_deposit_transactions, :voided_at
    add_index :security_deposit_transactions, :superseded_by_id, unique: true, where: "superseded_by_id IS NOT NULL", name: "index_sdt_on_unique_superseded_by_id"
  end
end
