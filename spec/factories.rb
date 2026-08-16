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

  factory :property do
    association :user
    sequence(:address) { |n| "#{n} Main St" }
    asset_type { "single_family" }
    square_footage { 1500 }
  end

  factory :rentable_unit do
    association :property
    sequence(:name) { |n| "Unit #{n}" }
    sequence(:unit_identifier) { |n| "#{100 + n}" }
    square_footage { 1200 }
    active { true }
  end

  factory :party do
    association :user
    sequence(:display_name) { |n| "Party #{n}" }
    party_type { "individual" }
    mailing_address { "123 Street" }
    phone_number { "555-5555" }
    email_address { "party@example.com" }
  end

  factory :party_alias do
    association :party
    sequence(:alias_name) { |n| "Alias #{n}" }
  end

  factory :tenancy do
    association :rentable_unit
    agreement_type { "fixed_term" }
    commencement_date { Date.current }
    termination_date { Date.current + 1.year }
    late_period_days { 5 }

    trait :month_to_month do
      agreement_type { "month_to_month" }
      termination_date { nil }
    end
  end

  factory :tenancy_party do
    association :tenancy
    party { association :party, user: tenancy.rentable_unit.property.user }
    role { "tenant" }
    effective_from { tenancy&.commencement_date || Date.current }
    effective_until { tenancy&.termination_date }
  end

  factory :rent_term do
    association :tenancy
    amount_cents { 120_000 }
    due_day { 1 }
    frequency { "monthly" }
    effective_from { tenancy&.commencement_date || Date.current }
    effective_until { tenancy&.termination_date }
  end

  factory :scheduled_rent do
    association :tenancy
    amount { 1200.0 }
    due_date { Date.current }
  end

  factory :tenant_payment do
    association :tenancy
    amount { 1200.0 }
    payment_date { Date.current }
    payment_method { "check" }
    sequence(:transaction_number) { |n| "TXN#{n}" }
  end

  factory :expense do
    association :property
    category { "repairs" }
    amount { 100.0 }
    expense_date { Date.current }
    description { "Fixing faucet" }
  end

  factory :tenant_charge do
    association :tenancy
    association :expense
    amount { 100.0 }
    charge_date { Date.current }
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

  factory :account do
    association :user
    sequence(:key) { |n| "custom_account_#{n}" }
    sequence(:name) { |n| "Custom Account #{n}" }
    account_type { "asset" }
    active { true }
  end

  factory :journal_entry do
    association :user
    source_type { "Expense" }
    sequence(:source_id) { |n| 1000 + n }
    event_type { "expense_posted" }
    occurred_on { Date.current }
    posted_at { Time.current }
    description { "Test journal entry" }
  end

  factory :posting do
    association :journal_entry
    account { association :account, user: journal_entry.user }
    amount_cents { 10_000 }
  end
end
