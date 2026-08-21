json.extract! scheduled_rent, :id, :tenancy_id, :amount, :due_date, :created_at, :updated_at
json.url scheduled_rent_url(scheduled_rent, format: :json)
