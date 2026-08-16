class CreateCharges < ActiveRecord::Migration[8.1]
  def change
    create_table :charges do |t|
      t.references :tenancy, null: false, foreign_key: true
      t.string :charge_kind, null: false
      t.bigint :amount_cents, null: false
      t.date :charge_date, null: false
      t.date :due_on, null: false
      t.string :description
      t.references :rent_term, foreign_key: true
      t.references :source_expense, foreign_key: { to_table: :expenses }
      t.date :service_period_start
      t.date :service_period_end
      t.datetime :posted_at
      t.datetime :voided_at
      t.references :superseded_by, foreign_key: { to_table: :charges }

      t.timestamps
    end

    add_index :charges, :charge_kind
    add_index :charges, :charge_date
    add_index :charges, :due_on
    add_index :charges, :service_period_start
    add_index :charges, :voided_at

    add_index :charges, %i[tenancy_id service_period_start],
      unique: true,
      where: "charge_kind = 'rent' AND voided_at IS NULL",
      name: "index_charges_on_tenancy_and_service_period_for_live_rent"

    add_check_constraint :charges,
      "amount_cents > 0",
      name: "charges_amount_cents_positive"

    add_check_constraint :charges,
      "service_period_end IS NULL OR service_period_start IS NULL OR service_period_end >= service_period_start",
      name: "charges_service_period_valid"

    add_check_constraint :charges,
      "charge_kind IN ('rent', 'late_fee', 'reimbursement', 'other')",
      name: "charges_charge_kind_valid"
  end
end
