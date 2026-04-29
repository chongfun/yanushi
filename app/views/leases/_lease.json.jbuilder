json.extract! lease, :id, :rental_property_id, :lease_type, :commencement_date, :termination_date, :annual_rental_amount, :late_period_days, :created_at, :updated_at
json.url lease_url(lease, format: :json)
