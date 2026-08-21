json.extract! @charge, :id, :tenancy_id, :charge_kind, :amount_cents, :amount, :charge_date, :due_on, :description, :posted_at, :voided_at, :superseded_by_id, :created_at, :updated_at
json.url charge_url(@charge, format: :json)
