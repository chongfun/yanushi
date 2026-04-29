json.extract! utility_payment, :id, :tenant_id, :rental_property_id, :amount, :payment_date, :created_at, :updated_at
json.url utility_payment_url(utility_payment, format: :json)
