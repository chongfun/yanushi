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

  factory :receipt do
    association :tenancy
    user { tenancy.rentable_unit.property.user }
    payer_party { association :party, user: user }
    amount_cents { 120_000 }
    received_on { Date.current }
    payment_method { "check" }
    sequence(:external_reference) { |n| "REC#{n}" }

    trait :posted do
      posted_at { Time.current }
    end

    trait :voided do
      posted_at { 1.day.ago }
      voided_at { Time.current }
    end

    trait :superseded do
      posted_at { 1.day.ago }
      voided_at { Time.current }
      superseded_by { association :receipt, tenancy: tenancy, user: user, payer_party: payer_party }
    end
  end

  factory :expense do
    association :property
    expense_kind { "repairs" }
    amount_cents { 10_000 }
    paid_on { Date.current }
    description { "Fixing faucet" }
    vendor_name { "Plumbing Pros" }
    external_reference { "INV-1001" }

    trait :property_wide do
      rentable_unit { nil }
    end

    trait :unit_scoped do
      rentable_unit { association :rentable_unit, property: property }
    end

    trait :posted do
      posted_at { Time.current }
    end

    trait :voided do
      posted_at { 1.day.ago }
      voided_at { Time.current }
    end

    trait :superseded do
      posted_at { 1.day.ago }
      voided_at { Time.current }
      superseded_by { association :expense, property: property }
    end
  end

  factory :source_document do
    association :user
    document_type { "unknown" }
    sequence(:attachment_file) { |n| "%PDF-1.4\nattachment_file_#{n}" }
    attachment_filename { "receipt.pdf" }
    attachment_content_type { "application/pdf" }
    status { "processing" }
  end

  factory :imported_transaction do
    association :user
    source_document { association :source_document, user: user }
    source { "pdf_upload" }
    transaction_kind { "unknown" }
    status { "pending" }

    trait :tenant_receipt do
      transaction_kind { "tenant_receipt" }
      payment_method { "zelle" }
    end

    trait :security_deposit do
      transaction_kind { "security_deposit" }
      payment_method { "zelle" }
    end

    trait :matched do
      status { "matched" }
      matched_party { association :party, user: user }
      matched_tenancy do
        property = association(:property, user: user)
        unit = association(:rentable_unit, property: property)
        association(:tenancy, rentable_unit: unit)
      end
      amount_cents { 100_000 }
      occurred_on { Date.current }
    end

    trait :unmatched do
      status { "unmatched" }
      amount_cents { 100_000 }
      occurred_on { Date.current }
    end

    trait :ambiguous do
      status { "ambiguous" }
      amount_cents { 100_000 }
      occurred_on { Date.current }
    end

    trait :confirmed_receipt do
      status { "confirmed" }
      transaction_kind { "tenant_receipt" }
      payment_method { "zelle" }
      amount_cents { 100_000 }
      occurred_on { Date.current }
      sequence(:external_reference) { |n| "ZEL-CONF-#{n}" }
      matched_party { association :party, user: user }
      matched_tenancy do
        property = association(:property, user: user)
        unit = association(:rentable_unit, property: property)
        association(:tenancy, rentable_unit: unit)
      end
      confirmed_source do
        association :receipt,
                    user: user,
                    tenancy: matched_tenancy,
                    payer_party: matched_party,
                    amount_cents: amount_cents,
                    received_on: occurred_on,
                    payment_method: payment_method,
                    external_reference: external_reference
      end
    end

    trait :confirmed_security_deposit do
      status { "confirmed" }
      transaction_kind { "security_deposit" }
      payment_method { "zelle" }
      amount_cents { 100_000 }
      occurred_on { Date.current }
      sequence(:external_reference) { |n| "DEP-CONF-#{n}" }
      matched_party { association :party, user: user }
      matched_tenancy do
        property = association(:property, user: user)
        unit = association(:rentable_unit, property: property)
        association(:tenancy, rentable_unit: unit)
      end
      confirmed_source do
        deposit = association(:security_deposit, tenancy: matched_tenancy, required_amount_cents: amount_cents)
        association :security_deposit_transaction,
                    security_deposit: deposit,
                    party: matched_party,
                    amount_cents: amount_cents,
                    transaction_kind: "received",
                    occurred_on: occurred_on,
                    external_reference: external_reference
      end
    end
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

  factory :charge do
    association :tenancy
    charge_kind { "other" }
    amount_cents { 10_000 }
    charge_date { Date.current }
    due_on { Date.current }
    description { "General charge" }

    trait :rent_charge do
      charge_kind { "rent" }
      description { "Monthly Rent" }
      rent_term do
        association :rent_term,
          tenancy: tenancy,
          amount_cents: amount_cents,
          effective_from: tenancy.commencement_date,
          effective_until: tenancy.termination_date
      end
      service_period_start { tenancy.commencement_date || Date.current.beginning_of_month }
      service_period_end { tenancy.termination_date || (service_period_start + 1.month - 1.day) }
    end

    trait :late_fee_charge do
      charge_kind { "late_fee" }
      description { "Late Fee" }
    end

    trait :reimbursement_charge do
      charge_kind { "reimbursement" }
      description { "Utility Reimbursement" }
      source_expense do
        association :expense,
          property: tenancy.property || association(:property, user: tenancy.accounting_user)
      end
    end

    trait :other_charge do
      charge_kind { "other" }
      description { "Other Charge" }
    end

    trait :voided_charge do
      voided_at { Time.current }
    end

    trait :posted do
      posted_at { Time.current }
    end
  end

  factory :security_deposit do
    association :tenancy
    required_amount_cents { 200_000 }
    due_on { tenancy&.commencement_date || Date.current }
  end

  factory :security_deposit_transaction do
    association :security_deposit
    transaction_kind { "received" }
    amount_cents { 200_000 }
    occurred_on { Date.current }
    party { association :party, user: security_deposit.accounting_user }

    trait :received do
      transaction_kind { "received" }
      party { association :party, user: security_deposit.accounting_user }
      charge { nil }
    end

    trait :refunded do
      transaction_kind { "refunded" }
      party { association :party, user: security_deposit.accounting_user }
      charge { nil }
    end

    trait :applied do
      transaction_kind { "applied" }
      party { nil }
      charge { association :charge, tenancy: security_deposit.tenancy }
    end

    trait :posted do
      after(:create) do |txn|
        txn.update_columns(posted_at: Time.current)
      end
    end

    trait :voided do
      after(:create) do |txn|
        txn.update_columns(posted_at: 1.day.ago, voided_at: Time.current)
      end
    end

    trait :superseded do
      after(:create) do |txn|
        rep = create(:security_deposit_transaction, :received, security_deposit: txn.security_deposit)
        txn.update_columns(posted_at: 1.day.ago, voided_at: Time.current, superseded_by_id: rep.id)
      end
    end
  end

  factory :property_tax_profile do
    property
    tax_year { Date.current.year }
    schedule_e_property_type { "single_family_residence" }
    other_description { nil }

    trait :other do
      schedule_e_property_type { "other" }
      other_description { "Warehouse storage" }
    end
  end

  factory :property_tax_review_resolution do
    property
    journal_entry do
      entry = association :journal_entry, user: property.user, occurred_on: Date.new(tax_year, 6, 1), event_type: "custom_income", source: property
      cash_acct = property.user.accounts.find_by(key: "cash") || create(:account, user: property.user, key: "cash", account_type: "asset")
      equity_acct = property.user.accounts.find_by(key: "opening_balance_equity") || create(:account, user: property.user, key: "opening_balance_equity", account_type: "equity")
      create(:posting, journal_entry: entry, property: property, amount_cents: 10_000, account: cash_acct)
      create(:posting, journal_entry: entry, property: property, amount_cents: -10_000, account: equity_acct)
      entry
    end
    tax_year { Date.current.year }
    treatment { "include_in_rents" }
    notes { "Security deposit retained for unpaid rent" }

    trait :exclude do
      treatment { "exclude" }
      notes { "Tenant damage reimbursement, reported elsewhere" }
    end
  end
end
