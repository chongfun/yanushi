json.extract! rent_payment, :id, :scheduled_rent_id, :payment_date, :amount, :payment_method, :created_at, :updated_at
json.url rent_payment_url(rent_payment, format: :json)
