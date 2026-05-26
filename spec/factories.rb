FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password" }
  end

  factory :session do
    association :user
    ip_address { "127.0.0.1" }
    user_agent { "TestAgent" }
  end

  factory :rental_property do
    association :user
    sequence(:address) { |n| "#{n} Main St" }
    property_type { :single_family_residence }
    square_footage { 1500 }
  end

  factory :lease do
    association :rental_property
    lease_type { :term }
    commencement_date { Date.today }
    termination_date { Date.today + 1.year }
    annual_rental_amount { 12000.0 }
    late_period_days { 5 }
    security_deposit { 500.0 }
  end

  factory :tenant do
    association :user
    sequence(:name) { |n| "Tenant #{n}" }
    mailing_address { "123 Street" }
    phone_number { "555-5555" }
    email_address { "tenant@example.com" }
  end

  factory :lease_tenant do
    association :lease
    association :tenant
  end

  factory :tenant_alias do
    association :tenant
    sequence(:alias_name) { |n| "Alias #{n}" }
  end

  factory :scheduled_rent do
    association :lease
    amount { 1000.0 }
    due_date { Date.today }
  end

  factory :tenant_payment do
    association :lease
    amount { 1000.0 }
    payment_date { Date.today }
    payment_method { "check" }
    sequence(:transaction_number) { |n| "TXN#{n}" }
  end

  factory :expense do
    association :rental_property
    category { "repairs" }
    amount { 100.0 }
    expense_date { Date.today }
    description { "Fixing faucet" }
  end

  factory :tenant_charge do
    association :lease
    association :expense
    amount { 100.0 }
    charge_date { Date.today }
    description { "Reimbursable repair" }
  end

  factory :payment_document do
    association :user
    attachment_file { "pdf bytes" }
    attachment_filename { "receipt.pdf" }
    attachment_content_type { "application/pdf" }
  end

  factory :payment_ingestion do
    association :user
    source { "pdf_upload" }
    status { "pending" }
  end
end
