json.extract! party, :id, :display_name, :party_type, :email_address, :phone_number, :mailing_address, :created_at, :updated_at
json.url party_url(party, format: :json)
