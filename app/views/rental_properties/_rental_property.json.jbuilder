json.extract! rental_property, :id, :user_id, :address, :property_type, :square_footage, :created_at, :updated_at
json.url rental_property_url(rental_property, format: :json)
