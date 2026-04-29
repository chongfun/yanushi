json.extract! tenant, :id, :user_id, :name, :mailing_address, :phone_number, :email_address, :created_at, :updated_at
json.url tenant_url(tenant, format: :json)
