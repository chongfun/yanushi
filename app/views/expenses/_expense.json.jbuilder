json.extract! expense, :id, :rental_property_id, :category, :amount, :expense_date, :description, :created_at, :updated_at
json.url expense_url(expense, format: :json)
