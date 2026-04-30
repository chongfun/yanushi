json.extract! utility_payment, :id, :lease_id, :amount, :payment_date, :payment_method, :transaction_number, :created_at, :updated_at
json.url utility_payment_url(utility_payment, format: :json)
