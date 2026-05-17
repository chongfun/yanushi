# Implementation Plan: Email Payment Ingestion (Zelle / Venmo)

## Overview

Automatically retrieve forwarded Zelle/Venmo payment notifications from an email inbox and create the appropriate `RentPayment` or `UtilityPayment` records. The system will match the payer's name to a tenant (supporting aliases for name changes), determine whether the payment corresponds to an outstanding utility expense or unpaid scheduled rent, and create the correct payment record.

---

## Current Data Model (Relevant Subset)

```
User
 ├── RentalProperty
 │    ├── Lease
 │    │    ├── LeaseTenant → Tenant
 │    │    ├── ScheduledRent → RentPayment
 │    │    └── UtilityPayment
 │    └── Expense (category enum includes "utilities")
 └── Tenant
```

### Key Observations

- **Utility payments** (`utility_payments`) belong to a `Lease` but have **no foreign key to `Expense`**. There is currently no programmatic link between a utility payment received from a tenant and the corresponding utility expense recorded against the property.
- **Expenses** with `category: "utilities"` are tracked per `RentalProperty`, not per `Lease`.
- **Tenants** have a single `name` field — no alias support exists today.
- **No email integration** exists in the application.

---

## Phase 1 — Schema Changes

### 1.1 Tenant Aliases

Add a `tenant_aliases` table to support multiple names per tenant (e.g., maiden name, legal name change).

```ruby
# db/migrate/XXXXXXXX_create_tenant_aliases.rb
create_table :tenant_aliases do |t|
  t.references :tenant, null: false, foreign_key: true
  t.string     :name,   null: false
  t.timestamps
end

add_index :tenant_aliases, [:tenant_id, :name], unique: true
```

**Model:**

```ruby
# app/models/tenant_alias.rb
class TenantAlias < ApplicationRecord
  belongs_to :tenant
  validates :name, presence: true, uniqueness: { scope: :tenant_id }
end
```

**Update `Tenant` model:**

```ruby
class Tenant < ApplicationRecord
  has_many :tenant_aliases, dependent: :destroy
  accepts_nested_attributes_for :tenant_aliases, allow_destroy: true, reject_if: :all_blank

  # Returns all matchable names (primary + aliases), downcased
  def all_names
    [name, *tenant_aliases.pluck(:name)].compact.map(&:downcase)
  end
end
```

### 1.2 Link Utility Payments to Expenses

Add an optional `expense_id` foreign key to `utility_payments` so that a tenant's utility payment can be associated with the specific utility expense it reimburses.

```ruby
# db/migrate/XXXXXXXX_add_expense_id_to_utility_payments.rb
add_reference :utility_payments, :expense, null: true, foreign_key: true
```

**Update `UtilityPayment` model:**

```ruby
class UtilityPayment < ApplicationRecord
  belongs_to :lease
  belongs_to :expense, optional: true
end
```

### 1.3 Email Ingestion Log

Track every processed email to prevent duplicate payment creation and provide an audit trail.

```ruby
# db/migrate/XXXXXXXX_create_payment_emails.rb
create_table :payment_emails do |t|
  t.references :user,            null: false, foreign_key: true
  t.string     :message_id,      null: false  # RFC 2822 Message-ID for deduplication
  t.string     :sender_name                   # Parsed payer name from email body
  t.decimal    :amount                         # Parsed amount
  t.date       :payment_date                   # Parsed date
  t.string     :transaction_id                 # Parsed Zelle/Venmo transaction number
  t.string     :provider                       # "zelle" or "venmo"
  t.string     :status,          null: false, default: "pending"
  # status enum: pending, matched_rent, matched_utility, unmatched, error
  t.string     :error_message
  t.references :rent_payment,    null: true, foreign_key: true
  t.references :utility_payment, null: true, foreign_key: true
  t.text       :raw_body                       # Original email body for debugging
  t.timestamps
end

add_index :payment_emails, [:user_id, :message_id], unique: true
```

**Model:**

```ruby
# app/models/payment_email.rb
class PaymentEmail < ApplicationRecord
  belongs_to :user
  belongs_to :rent_payment,    optional: true
  belongs_to :utility_payment, optional: true

  enum :status, {
    pending:          "pending",
    matched_rent:     "matched_rent",
    matched_utility:  "matched_utility",
    unmatched:        "unmatched",
    error:            "error"
  }

  validates :message_id, presence: true, uniqueness: { scope: :user_id }
end
```

### 1.4 Per-User Email Configuration

Since this is a multi-user application, IMAP credentials are stored per-user in the database rather than in Rails credentials.

```ruby
# db/migrate/XXXXXXXX_create_email_configurations.rb
create_table :email_configurations do |t|
  t.references :user,        null: false, foreign_key: true, index: { unique: true }
  t.string     :imap_server, null: false  # e.g. "imap.gmail.com"
  t.integer    :imap_port,   null: false, default: 993
  t.string     :username,    null: false
  t.string     :password,    null: false  # Encrypted via Active Record Encryption
  t.string     :mailbox,     null: false, default: "INBOX"
  t.boolean    :ssl,         null: false, default: true
  t.boolean    :enabled,     null: false, default: true
  t.datetime   :last_polled_at
  t.timestamps
end
```

**Model:**

```ruby
# app/models/email_configuration.rb
class EmailConfiguration < ApplicationRecord
  belongs_to :user

  encrypts :password

  validates :imap_server, :username, :password, presence: true
  validates :imap_port, numericality: { only_integer: true, greater_than: 0 }
end
```

**Update `User` model:**

```ruby
class User < ApplicationRecord
  has_one :email_configuration, dependent: :destroy
end
```

---

## Phase 2 — Email Connection & Retrieval

### 2.1 Approach: IMAP Polling via Solid Queue Recurring Job

Since the application already uses **Solid Queue** for background jobs (see `config/recurring.yml`), the simplest approach is a recurring job that polls each user's IMAP mailbox for new forwarded payment emails. This avoids the operational overhead of configuring Action Mailbox ingress routing.

Payment notification emails may arrive via **manual forwarding** or **auto-forwarding rules** — the system handles both identically since it processes all unseen messages in the configured mailbox.

### 2.2 Recurring Job Configuration

```yaml
# config/recurring.yml  (add to all environments or production-only)
production:
  ingest_payment_emails:
    class: IngestPaymentEmailsJob
    schedule: every 15 minutes
```

### 2.3 IMAP Polling Job

The job iterates over all users who have an enabled `EmailConfiguration`, polling each user's mailbox independently.

```ruby
# app/jobs/ingest_payment_emails_job.rb
class IngestPaymentEmailsJob < ApplicationJob
  queue_as :default

  def perform
    EmailConfiguration.where(enabled: true).find_each do |config|
      poll_mailbox(config)
    rescue => e
      Rails.logger.error("Email ingestion failed for user #{config.user_id}: #{e.message}")
    end
  end

  private

  def poll_mailbox(config)
    imap = Net::IMAP.new(config.imap_server, port: config.imap_port, ssl: config.ssl)
    imap.login(config.username, config.password)
    imap.select(config.mailbox)

    # Search for UNSEEN messages
    message_ids = imap.search(["UNSEEN"])

    message_ids.each do |msg_id|
      envelope = imap.fetch(msg_id, "ENVELOPE").first.attr["ENVELOPE"]
      body = imap.fetch(msg_id, "BODY[TEXT]").first.attr["BODY[TEXT]"]
      rfc_message_id = envelope.message_id

      PaymentEmailProcessorService.new(
        message_id: rfc_message_id,
        body: body,
        received_at: Time.current,
        user: config.user
      ).call

      # Mark as seen
      imap.store(msg_id, "+FLAGS", [:Seen])
    end

    config.update!(last_polled_at: Time.current)
    imap.logout
    imap.disconnect
  end
end
```

---

## Phase 3 — Email Parsing Service

### 3.1 Parser Strategy

Payment emails are forwarded from **Chase Bank** (Zelle) and **Venmo**. Each source uses predictable email templates, so the parser includes tailored regex pattern sets for both providers. If additional sources need support in the future, the parser can be extended with new pattern sets.

The parser should extract:

| Field              | Chase Zelle Example                           | Venmo Example                                |
|--------------------|-----------------------------------------------|--------------------------------------------------|
| **Payer name**     | "Jane Doe sent you $1,200.00"                 | "Jane Doe paid you $1,200.00"                |
| **Amount**         | "$1,200.00"                                   | "$1,200.00"                                   |
| **Date**           | "on May 15, 2026"                             | "May 15, 2026"                                |
| **Transaction ID** | "Confirmation: 20260515-ABCD1234"             | "Transaction ID: 1234567890123456"            |
| **Provider**       | "Zelle"                                       | "Venmo"                                       |

### 3.2 Service Class

```ruby
# app/services/payment_email_parser_service.rb
class PaymentEmailParserService
  class UnknownProviderError < StandardError; end

  # Chase Bank Zelle notification patterns
  CHASE_ZELLE_PATTERNS = {
    amount: /\$[\d,]+\.\d{2}/,
    sender: /(.+?)\s+sent\s+you/i,
    date:   /(?:on|dated?)\s+(\w+ \d{1,2},?\s*\d{4})/i,
    confirmation: /(?:confirmation|transaction)[\s#:]*([A-Z0-9-]+)/i
  }.freeze

  # Venmo notification patterns
  VENMO_PATTERNS = {
    amount: /\$[\d,]+\.\d{2}/,
    sender: /(.+?)\s+paid\s+you/i,
    date:   /(?:on|dated?)\s+(\w+ \d{1,2},?\s*\d{4})/i,
    confirmation: /(?:transaction\s*(?:id|#|:)|id\s*#?)\s*([A-Z0-9-]+)/i
  }.freeze

  PROVIDER_PATTERNS = {
    "zelle" => CHASE_ZELLE_PATTERNS,
    "venmo" => VENMO_PATTERNS
  }.freeze

  def initialize(body)
    @body = body
  end

  def parse
    provider = detect_provider
    patterns = PROVIDER_PATTERNS[provider]

    {
      provider:       provider,
      sender_name:    extract(patterns[:sender]),
      amount:         extract_amount(patterns[:amount]),
      payment_date:   extract_date(patterns[:date]),
      transaction_id: extract(patterns[:confirmation])
    }
  end

  private

  def detect_provider
    if @body.match?(/zelle/i)
      "zelle"
    elsif @body.match?(/venmo/i)
      "venmo"
    else
      raise UnknownProviderError, "Could not detect payment provider from email body"
    end
  end

  def extract(pattern)
    match = @body.match(pattern)
    match ? match[1]&.strip : nil
  end

  def extract_amount(pattern)
    match = @body.match(pattern)
    match ? match[0].gsub(/[$,]/, "").to_d : nil
  end

  def extract_date(pattern)
    match = @body.match(pattern)
    match ? Date.parse(match[1]) : nil
  rescue Date::Error
    nil
  end
end
```

> **Design Decision:** The parser uses a `PROVIDER_PATTERNS` lookup hash keyed by provider name, making it straightforward to add new providers. If additional banks are needed in the future, new pattern sets can be added to the hash and the `detect_provider` method extended.

---

## Phase 4 — Payment Routing Logic

This is the core business logic. Given a parsed email (payer name, amount, date), determine whether to create a `UtilityPayment` or `RentPayment`.

### 4.1 Resolution Algorithm

```
1. Resolve payer name → Tenant (using primary name + aliases)
2. Find all active Leases for that Tenant (scoped to the current User)
3. For each Lease:
   a. Find the Property associated with the Lease
   b. Check for a "utilities" Expense on that Property that:
      - Has no existing UtilityPayment linked to it (via expense_id)
      - Has an amount that exactly matches the payment amount
   c. If a matching utility expense is found → create UtilityPayment
4. If no utility match is found:
   a. Find the earliest unpaid ScheduledRent across all of the Tenant's Leases
   b. Create a RentPayment against that ScheduledRent
5. If no tenant match or no unpaid rent → mark as "unmatched"
```

### 4.2 Service Class

```ruby
# app/services/payment_email_processor_service.rb
class PaymentEmailProcessorService
  def initialize(message_id:, body:, received_at:, user:)
    @message_id  = message_id
    @body        = body
    @received_at = received_at
    @user        = user
  end

  def call
    # 1. Deduplicate
    return if PaymentEmail.exists?(user: @user, message_id: @message_id)

    # 2. Parse
    parsed = PaymentEmailParserService.new(@body).parse

    # 3. Create log record
    email_record = PaymentEmail.create!(
      user:           @user,
      message_id:     @message_id,
      sender_name:    parsed[:sender_name],
      amount:         parsed[:amount],
      payment_date:   parsed[:payment_date],
      transaction_id: parsed[:transaction_id],
      provider:       parsed[:provider],
      raw_body:       @body,
      status:         :pending
    )

    # 4. Resolve tenant
    tenant = resolve_tenant(parsed[:sender_name])
    unless tenant
      email_record.update!(status: :unmatched, error_message: "No tenant found matching '#{parsed[:sender_name]}'")
      return email_record
    end

    # 5. Try utility payment match first
    utility_payment = try_create_utility_payment(tenant, parsed)
    if utility_payment
      email_record.update!(status: :matched_utility, utility_payment: utility_payment)
      return email_record
    end

    # 6. Fall back to rent payment
    rent_payment = try_create_rent_payment(tenant, parsed)
    if rent_payment
      email_record.update!(status: :matched_rent, rent_payment: rent_payment)
      return email_record
    end

    # 7. No match — create in-app notification
    email_record.update!(status: :unmatched, error_message: "No unpaid utility expense or scheduled rent found for tenant '#{tenant.name}'")
    create_unmatched_notification(@user, email_record)
    email_record

  rescue => e
    email_record&.update(status: :error, error_message: e.message)
    create_unmatched_notification(@user, email_record) if email_record&.persisted?
    raise
  end

  private

  def resolve_tenant(payer_name)
    return nil if payer_name.blank?

    normalized = payer_name.downcase.strip

    # Check primary name first
    tenant = @user.tenants.find { |t| t.name.downcase == normalized }
    return tenant if tenant

    # Check aliases
    alias_match = TenantAlias.joins(:tenant)
                             .where(tenants: { user_id: @user.id })
                             .find_by("LOWER(tenant_aliases.name) = ?", normalized)
    alias_match&.tenant
  end

  def try_create_utility_payment(tenant, parsed)
    tenant.leases.includes(rental_property: :expenses).each do |lease|
      property = lease.rental_property

      # Find utility expenses that don't already have a linked payment
      utility_expenses = property.expenses
                                 .where(category: :utilities)
                                 .where.not(id: UtilityPayment.where.not(expense_id: nil).select(:expense_id))

      matching_expense = utility_expenses.find do |expense|
        expense.amount == parsed[:amount]
      end

      next unless matching_expense

      return UtilityPayment.create!(
        lease:              lease,
        expense:            matching_expense,
        amount:             parsed[:amount],
        payment_date:       parsed[:payment_date] || Date.current,
        payment_method:     parsed[:provider],
        transaction_number: parsed[:transaction_id]
      )
    end

    nil
  end

  def try_create_rent_payment(tenant, parsed)
    # Find earliest unpaid scheduled rent across all of the tenant's leases
    earliest_unpaid = ScheduledRent
      .joins(lease: :lease_tenants)
      .where(lease_tenants: { tenant_id: tenant.id })
      .where(paid: false)
      .order(:due_date)
      .first

    return nil unless earliest_unpaid

    RentPayment.create!(
      scheduled_rent:     earliest_unpaid,
      amount:             parsed[:amount],
      payment_date:       parsed[:payment_date] || Date.current,
      payment_method:     parsed[:provider],
      transaction_number: parsed[:transaction_id]
    )
  end

  def create_unmatched_notification(user, email_record)
    Notification.create!(
      user: user,
      title: "Unmatched payment email",
      message: "A #{email_record.provider} payment of #{email_record.amount} from '#{email_record.sender_name}' could not be matched.",
      notification_type: :payment_unmatched,
      read: false,
      payment_email: email_record
    )
  end
end
```

### 4.3 Edge Cases & Business Rules

| Scenario | Behavior |
|----------|----------|
| Payer name matches no tenant (primary or alias) | Mark `PaymentEmail` as `unmatched`; create in-app notification |
| Payer matches tenant but no utility expense or unpaid rent | Mark as `unmatched`; create in-app notification |
| Multiple utility expenses match the same amount | Match the **oldest** unlinked utility expense |
| Utility expense amount does not exactly match | Skip utility match; fall through to rent payment |
| Payment amount exceeds scheduled rent amount | Still create the `RentPayment`; the existing `update_scheduled_rent_status` callback handles partial/over payments |
| Duplicate email (same `message_id`) | Skip silently — uniqueness index prevents double-processing |
| Parse failure (no amount extracted) | Mark as `error` with descriptive message; create in-app notification |
| Tenant has leases on multiple properties | Check utility expenses on **all** properties; for rent, use the **earliest** unpaid `ScheduledRent` across all leases |

---

## Phase 5 — UI Changes

### 5.1 Tenant Alias Management

**Update tenant form** (`app/views/tenants/_form.html.erb`) to support adding/removing aliases via nested attributes:

- Add a "Name Aliases" section below the primary name field
- Use Stimulus controller for dynamic add/remove of alias fields
- Display existing aliases on the tenant show page (`app/views/tenants/show.html.erb`)

**Update `TenantsController`:**

```ruby
def tenant_params
  params.expect(tenant: [
    :user_id, :name, :mailing_address, :phone_number, :email_address,
    tenant_aliases_attributes: [:id, :name, :_destroy]
  ])
end
```

### 5.2 Payment Email Ingestion Dashboard

Add a new view to monitor the status of ingested payment emails:

- **Route:** `GET /payment_emails` — list all ingested emails with status badges
- **Columns:** Date, Payer Name, Amount, Provider, Status, Linked Payment
- **Filters:** Status (pending, matched, unmatched, error)
- **Action:** Manual "retry" button for `unmatched` or `error` records
- **Action:** Manual "Run Now" button to trigger `IngestPaymentEmailsJob` on demand

**New files:**
- `app/controllers/payment_emails_controller.rb`
- `app/views/payment_emails/index.html.erb`
- Add route: `resources :payment_emails, only: [:index, :show]`

### 5.3 Email Configuration Settings Page

Each user configures their own IMAP credentials via a settings page:

- **Route:** `GET /settings/email` — form for IMAP server, port, username, password, mailbox, SSL toggle, enabled toggle
- **Route:** `PATCH /settings/email` — update credentials
- Password encrypted at rest via Active Record Encryption (`encrypts :password`)
- Display `last_polled_at` timestamp so the user knows when the mailbox was last checked
- "Test Connection" button to validate IMAP credentials before saving

**New files:**
- `app/controllers/email_configurations_controller.rb`
- `app/views/email_configurations/edit.html.erb`
- Add routes: `resource :email_configuration, only: [:edit, :update]`

### 5.4 In-App Notifications for Unmatched Payments

When a payment email cannot be matched to a tenant, utility expense, or scheduled rent, the system creates an in-app notification visible from the dashboard.

#### 5.4.1 Notifications Schema

```ruby
# db/migrate/XXXXXXXX_create_notifications.rb
create_table :notifications do |t|
  t.references :user,          null: false, foreign_key: true
  t.string     :title,         null: false
  t.text       :message
  t.string     :notification_type, null: false  # e.g. "payment_unmatched"
  t.boolean    :read,          null: false, default: false
  t.references :payment_email, null: true, foreign_key: true
  t.timestamps
end
```

**Model:**

```ruby
# app/models/notification.rb
class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :payment_email, optional: true

  enum :notification_type, {
    payment_unmatched: "payment_unmatched",
    payment_error:     "payment_error"
  }

  scope :unread, -> { where(read: false) }
end
```

#### 5.4.2 UI Elements

- **Notification bell** in the application layout header with an unread count badge
- **Dropdown/page** listing recent notifications with links to the relevant `PaymentEmail` record
- Mark as read on click or via "Mark all as read" action

**New files:**
- `app/controllers/notifications_controller.rb`
- `app/views/notifications/index.html.erb`
- `app/views/layouts/_notification_bell.html.erb` (partial for header)
- Add routes: `resources :notifications, only: [:index, :update]`

---

## Phase 6 — Testing Strategy

### 6.1 Unit Tests

| Test File | Coverage |
|-----------|----------|
| `test/models/tenant_alias_test.rb` | Validations, uniqueness, association |
| `test/models/tenant_test.rb` | `#all_names` returns primary + aliases |
| `test/models/payment_email_test.rb` | Validations, enum, deduplication |
| `test/models/email_configuration_test.rb` | Validations, encryption, association |
| `test/models/notification_test.rb` | Validations, scopes, enum |

### 6.2 Service Tests

| Test File | Coverage |
|-----------|----------|
| `test/services/payment_email_parser_service_test.rb` | Chase Zelle parsing, Venmo parsing, edge cases (missing fields, unusual formats) |
| `test/services/payment_email_processor_service_test.rb` | Full routing logic — utility exact-amount match, rent fallback, unmatched + notification creation, duplicate handling, alias resolution |

### 6.3 Integration Tests

| Test File | Coverage |
|-----------|----------|
| `test/controllers/payment_emails_controller_test.rb` | Index filtering, show page |
| `test/controllers/email_configurations_controller_test.rb` | Edit, update, credential encryption |
| `test/controllers/notifications_controller_test.rb` | Index, mark as read |
| `test/integration/payment_ingestion_flow_test.rb` | End-to-end: email → parse → route → payment created |

### 6.4 Fixtures

Add fixtures for:
- Tenants with aliases
- Properties with utility expenses (category: `utilities`)
- Leases linking tenants to properties
- Unpaid scheduled rents
- Sample Chase Bank Zelle email bodies and Venmo email bodies
- Email configurations per user

---

## Migration Execution Order

1. `CreateTenantAliases` — new table
2. `AddExpenseIdToUtilityPayments` — add column
3. `CreateEmailConfigurations` — new table (per-user IMAP credentials)
4. `CreatePaymentEmails` — new table
5. `CreateNotifications` — new table

---

## File Change Summary

| Action | Path |
|--------|------|
| **Create** | `db/migrate/XXXXX_create_tenant_aliases.rb` |
| **Create** | `db/migrate/XXXXX_add_expense_id_to_utility_payments.rb` |
| **Create** | `db/migrate/XXXXX_create_email_configurations.rb` |
| **Create** | `db/migrate/XXXXX_create_payment_emails.rb` |
| **Create** | `db/migrate/XXXXX_create_notifications.rb` |
| **Create** | `app/models/tenant_alias.rb` |
| **Create** | `app/models/email_configuration.rb` |
| **Create** | `app/models/payment_email.rb` |
| **Create** | `app/models/notification.rb` |
| **Modify** | `app/models/tenant.rb` — add `has_many :tenant_aliases`, `all_names` method |
| **Modify** | `app/models/user.rb` — add `has_one :email_configuration` |
| **Modify** | `app/models/utility_payment.rb` — add `belongs_to :expense, optional: true` |
| **Create** | `app/services/payment_email_parser_service.rb` |
| **Create** | `app/services/payment_email_processor_service.rb` |
| **Create** | `app/jobs/ingest_payment_emails_job.rb` |
| **Modify** | `config/recurring.yml` — add `ingest_payment_emails` entry |
| **Modify** | `app/controllers/tenants_controller.rb` — permit alias nested attributes |
| **Modify** | `app/views/tenants/_form.html.erb` — add alias fields |
| **Modify** | `app/views/tenants/show.html.erb` — display aliases |
| **Create** | `app/controllers/payment_emails_controller.rb` |
| **Create** | `app/views/payment_emails/index.html.erb` |
| **Create** | `app/controllers/email_configurations_controller.rb` |
| **Create** | `app/views/email_configurations/edit.html.erb` |
| **Create** | `app/controllers/notifications_controller.rb` |
| **Create** | `app/views/notifications/index.html.erb` |
| **Create** | `app/views/layouts/_notification_bell.html.erb` |
| **Modify** | `config/routes.rb` — add `payment_emails`, `email_configuration`, `notifications` resources |
| **Create** | `test/models/tenant_alias_test.rb` |
| **Create** | `test/models/payment_email_test.rb` |
| **Create** | `test/models/email_configuration_test.rb` |
| **Create** | `test/models/notification_test.rb` |
| **Create** | `test/services/payment_email_parser_service_test.rb` |
| **Create** | `test/services/payment_email_processor_service_test.rb` |
| **Create** | `test/controllers/payment_emails_controller_test.rb` |
| **Create** | `test/controllers/email_configurations_controller_test.rb` |
| **Create** | `test/controllers/notifications_controller_test.rb` |
| **Create** | `test/integration/payment_ingestion_flow_test.rb` |

---

## Resolved Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | **Single-user or multi-user IMAP?** | **Multi-user.** Each user stores their own IMAP credentials in the `email_configurations` table. Passwords are encrypted via Active Record Encryption. |
| 2 | **Payment provider coverage** | **Chase Bank (Zelle) and Venmo.** The parser uses provider-specific regex patterns for both sources, organized in a `PROVIDER_PATTERNS` lookup hash. |
| 3 | **Utility expense matching tolerance** | **Exact match.** The utility payment amount must exactly equal the expense amount — no tolerance. |
| 4 | **Forwarding mechanism** | **Both manual and auto-forwarded.** The system processes all unseen messages in the configured mailbox identically regardless of how they arrived. |
| 5 | **Notification on unmatched** | **In-app notification.** The system creates a `Notification` record visible from the dashboard with an unread badge in the header. No email notifications. |
