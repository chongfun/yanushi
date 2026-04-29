json.extract! scheduled_rent, :id, :lease_id, :expected_amount, :expected_due_date, :created_at, :updated_at
json.url scheduled_rent_url(scheduled_rent, format: :json)
