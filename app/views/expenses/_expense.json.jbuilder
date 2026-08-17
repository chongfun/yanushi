json.extract! expense, :id, :property_id, :rentable_unit_id, :expense_kind, :amount_cents, :amount, :paid_on, :vendor_name, :external_reference, :description, :posted_at, :voided_at, :superseded_by_id, :created_at, :updated_at
json.url expense_url(expense, format: :json)
