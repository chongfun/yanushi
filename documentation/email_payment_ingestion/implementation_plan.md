# Implementation Plan: Email Payment Ingestion (Zelle / Venmo)

## Overview

Automatically retrieve forwarded Zelle/Venmo payment notifications from an email inbox and create the appropriate `TenantPayment` records. The system will match the payer's name to a tenant (supporting aliases for name changes) and create a credit on their running lease account ledger.

---

## Current Data Model (Relevant Subset)

```
User
 ├── RentalProperty
 │    ├── Lease
 │    │    ├── LeaseTenant → Tenant
 │    │    ├── ScheduledRent
 │    │    ├── TenantCharge → Expense
 │    │    └── TenantPayment
 │    └── Expense (category enum includes "utilities")
 └── Tenant
```

### Key Observations

- **Tenant payments** (`tenant_payments`) belong to a `Lease` and act as credits on the running account ledger.
- **Expenses** are tracked per `RentalProperty`, and can optionally be linked to a `TenantCharge` if reimbursable.
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


### 1.2 Email Ingestion Log

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
  # status enum: pending, matched, unmatched, error
  t.string     :error_message
  t.references :tenant_payment,  null: true, foreign_key: true
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
  belongs_to :tenant_payment, optional: true

  enum :status, {
    pending:   "pending",
    matched:   "matched",
    unmatched: "unmatched",
    error:     "error"
  }

  validates :message_id, presence: true, uniqueness: { scope: :user_id }
end
```

### 1.3 Per-User Email Configuration

Since this is a multi-user application, Gmail API credentials are stored per-user in the database rather than in Rails credentials.

```ruby
# db/migrate/XXXXXXXX_create_email_configurations.rb
create_table :email_configurations do |t|
  t.references :user,                    null: false, foreign_key: true, index: { unique: true }
  t.string     :provider,                null: false, default: "gmail_api"
  t.string     :gmail_address,           null: false
  t.string     :google_refresh_token,    null: false
  t.string     :google_access_token,     null: false
  t.datetime   :google_token_expires_at, null: false
  t.boolean    :enabled,                 null: false, default: true
  t.datetime   :last_polled_at
  t.timestamps
end
```

**Model:**

```ruby
# app/models/email_configuration.rb
class EmailConfiguration < ApplicationRecord
  belongs_to :user

  encrypts :google_refresh_token, :google_access_token

  validates :gmail_address, :google_refresh_token, :google_access_token, presence: true
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

### 2.1 Approach: Gmail API Polling via Solid Queue Recurring Job

Since the application already uses **Solid Queue** for background jobs (see `config/recurring.yml`), the simplest approach is a recurring job that polls each user's inbox using the **Gmail API** for new forwarded payment emails. This avoids the operational overhead of configuring Action Mailbox ingress routing.

Payment notification emails may arrive via **manual forwarding** or **auto-forwarding rules** — the system handles both identically since it processes all unseen messages.

### 2.2 Recurring Job Configuration

```yaml
# config/recurring.yml  (add to all environments or production-only)
production:
  ingest_payment_emails:
    class: IngestPaymentEmailsJob
    schedule: every 15 minutes
```

### 2.3 Gmail API Client

The application uses a dedicated service class `GmailApiClient` to authenticate and fetch unseen emails.

```ruby
# app/services/gmail_api_client.rb
# Handles Google OAuth authentication, refreshing tokens, and fetching unread messages.
class GmailApiClient
  def initialize(config)
    @config = config
    # ... Google::Apis::GmailV1::GmailService setup ...
  end
  
  def list_unread_messages
    # ...
  end
  
  def get_raw_message(msg_id)
    # ...
  end
  
  def mark_as_read(msg_id)
    # ...
  end
end
```

### 2.4 API Polling Job

The job iterates over all users who have an enabled `EmailConfiguration`, polling each user's mailbox independently. It retrieves the raw `RFC822` email content for all unseen messages and delegates all parsing and business logic to the `PaymentEmailProcessorService`.

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
    client = GmailApiClient.new(config)
    messages = client.list_unread_messages

    messages.each do |msg_id|
      raw_source = client.get_raw_message(msg_id)

      PaymentEmailProcessorService.new(
        raw_source: raw_source,
        user:       config.user
      ).call

      client.mark_as_read(msg_id)
    end

    config.update!(last_polled_at: Time.current)
  end
end
```

---

## Phase 3 — Email Parsing Service

### 3.1 Parser Strategy

Payment emails are forwarded from **Chase Bank** (Zelle) and **Venmo**. The parser uses the raw email source to extract the clean, decoded subject line and decoded text/HTML body. The service is initialized with both the `subject` and the clean `body` text (which has had all HTML tags stripped to ensure robust matching).

Using the actual downloaded email fixtures in `test/fixtures/emails`, the parser should extract:

| Field | Chase Zelle Example (`zelle-rent-payment.eml`) | Venmo Example (`venmo-rent-payment.eml`) |
|---|---|---|
| **Raw Subject** | `"Fwd: You received money with Zelle®"` | `"samantha sanchez paid you $1,000.00"` |
| **Clean Body Text** | `"KRISTINA M PAGE sent you money\n...\nAmount $1200.00\nSent on Jul 31, 2024\nTransaction number 21569265114"` | `"samantha sanchez paid You\n...\nMar 29, 2024 PDT\n+ $1,000.00\nPayment ID: 4034689063827771191"` |
| **Payer name** | `"KRISTINA M PAGE"` (extracted from body) | `"samantha sanchez"` (extracted from subject or body) |
| **Amount** | `1200.00` | `1000.00` |
| **Date** | `2024-07-31` | `2024-03-29` |
| **Transaction ID** | `"21569265114"` | `"4034689063827771191"` |
| **Provider** | `"zelle"` | `"venmo"` |

### 3.2 Service Class

```ruby
# app/services/payment_email_parser_service.rb
class PaymentEmailParserService
  class UnknownProviderError < StandardError; end

  # Chase Bank Zelle notification patterns (matching real downloaded .eml files)
  CHASE_ZELLE_PATTERNS = {
    amount: /Amount\s+\$([\d,]+\.\d{2})/i,
    sender: /(.+?)\s+sent\s+you\s+money/i,
    date:   /Sent\s+on\s+(\w+\s+\d{1,2},\s*\d{4})/i,
    confirmation: /Transaction\s+number\s+(\d+)/i
  }.freeze

  # Venmo notification patterns (matching real downloaded .eml files)
  VENMO_PATTERNS = {
    # Amount is matched either in body (e.g. "+ $1,000.00") or in subject ("samantha sanchez paid you $1,000.00")
    amount: /(?:\+\s+\$|paid\s+you\s+\$)([\d,]+\.\d{2})/i,
    # Sender is matched in either subject or body before "paid you"
    sender: /(.+?)\s+paid\s+you/i,
    date:   /([A-Z][a-z]{2}\s+\d{1,2},\s*\d{4})/i,
    confirmation: /Payment\s+ID:\s*(\d+)/i
  }.freeze

  PROVIDER_PATTERNS = {
    "zelle" => CHASE_ZELLE_PATTERNS,
    "venmo" => VENMO_PATTERNS
  }.freeze

  def initialize(subject:, body:)
    @subject = subject.to_s
    @body = body.to_s
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
    combined = "#{@subject} #{@body}"
    if combined.match?(/venmo/i)
      "venmo"
    elsif combined.match?(/zelle/i)
      "zelle"
    else
      raise UnknownProviderError, "Could not detect payment provider from email subject or body"
    end
  end

  def extract(pattern)
    # Check body first, then subject
    match = @body.match(pattern) || @subject.match(pattern)
    match ? match[1]&.strip : nil
  end

  def extract_amount(pattern)
    match = @body.match(pattern) || @subject.match(pattern)
    match ? match[1].gsub(/,/, "").to_d : nil
  end

  def extract_date(pattern)
    match = @body.match(pattern) || @subject.match(pattern)
    match ? Date.parse(match[1]) : nil
  rescue Date::Error
    nil
  end
end
```

> **Design Decision:** The parser separates HTML decoding/stripping (handled by the processor) from pattern extraction. It accepts both subject and clean body text, allowing resilient regex matching from both sections. This ensures Venmo (where the payer/amount are often in the subject line) and Zelle (where they are in the body) are both cleanly parsed.

---

## Phase 4 — Payment Routing Logic

This is the core business logic. Given a parsed email (payer name, amount, date), determine the correct lease and create a `TenantPayment`.

### 4.1 Resolution Algorithm

```
1. Resolve payer name → Tenant (using primary name + aliases)
2. Find active Leases for that Tenant (scoped to the current User)
3. If no active leases, mark as "unmatched"
4. If active leases exist, find the one with the most negative balance (or just the first one if balances are >= 0)
5. Create a TenantPayment on that Lease
```

### 4.2 Service Class

```ruby
# app/services/payment_email_processor_service.rb
class PaymentEmailProcessorService
  def initialize(raw_source:, user:)
    @raw_source  = raw_source
    @user        = user
  end

  def call
    # 1. Parse raw email via Mail gem
    mail = Mail.read_from_string(@raw_source)
    message_id = mail.message_id

    # 2. Deduplicate
    return if PaymentEmail.exists?(user: @user, message_id: message_id)

    # 3. Extract text and strip HTML tags if multipart or HTML-only
    body_text = extract_body_text(mail)

    # 4. Parse fields
    parsed = PaymentEmailParserService.new(subject: mail.subject, body: body_text).parse

    # 5. Create log record
    email_record = PaymentEmail.create!(
      user:           @user,
      message_id:     message_id,
      sender_name:    parsed[:sender_name],
      amount:         parsed[:amount],
      payment_date:   parsed[:payment_date] || mail.date&.to_date || Date.current,
      transaction_id: parsed[:transaction_id],
      provider:       parsed[:provider],
      raw_body:       @raw_source,
      status:         :pending
    )

    # 6. Resolve tenant
    tenant = resolve_tenant(parsed[:sender_name])
    unless tenant
      email_record.update!(status: :unmatched, error_message: "No tenant found matching '#{parsed[:sender_name]}'")
      create_unmatched_notification(@user, email_record)
      return email_record
    end

    # 7. Try create tenant payment
    tenant_payment = try_create_tenant_payment(tenant, parsed)
    if tenant_payment
      email_record.update!(status: :matched, tenant_payment: tenant_payment)
      return email_record
    end

    # 8. No match — create in-app notification
    email_record.update!(status: :unmatched, error_message: "No active lease found for tenant '#{tenant.name}'")
    create_unmatched_notification(@user, email_record)
    email_record

  rescue => e
    email_record&.update(status: :error, error_message: e.message)
    create_unmatched_notification(@user, email_record) if email_record&.persisted?
    raise
  end

  private

  def extract_body_text(mail)
    raw_body = if mail.multipart?
      if mail.text_part&.body&.present?
        mail.text_part.decoded
      elsif mail.html_part&.body&.present?
        mail.html_part.decoded
      else
        ""
      end
    else
      mail.decoded
    end

    # If it is HTML, strip the tags to get clean plain text
    if mail.content_type&.include?("html") || (mail.multipart? && mail.text_part.nil? && mail.html_part.present?)
      ActionController::Base.helpers.strip_tags(raw_body)
    else
      raw_body
    end
  end

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

  def try_create_tenant_payment(tenant, parsed)
    # Find active leases for this tenant
    active_leases = tenant.leases.where(
      "commencement_date <= :today AND (termination_date IS NULL OR termination_date >= :today)",
      today: Date.current
    ).to_a

    return nil if active_leases.empty?

    # Prefer the lease with the most negative balance, otherwise just use the first active lease
    target_lease = active_leases.min_by { |lease| lease.current_balance }

    TenantPayment.create!(
      lease:              target_lease,
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
| Payer matches tenant but no active lease | Mark as `unmatched`; create in-app notification |
| Duplicate email (same `message_id`) | Skip silently — uniqueness index prevents double-processing |
| Parse failure (no amount extracted) | Mark as `error` with descriptive message; create in-app notification |
| Tenant has leases on multiple properties | Apply payment to the active lease with the most negative balance |

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

Each user configures their own Gmail API credentials via a settings page, typically starting an OAuth flow:

- **Route:** `GET /settings/email` — form to connect a Google Workspace account.
- **Route:** `PATCH /settings/email` — update configuration.
- Tokens encrypted at rest via Active Record Encryption.
- Display `last_polled_at` timestamp so the user knows when the mailbox was last checked

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
| `test/services/payment_email_parser_service_test.rb` | Verifies parser regex matching and extraction on the real email templates loaded from the `.eml` fixtures. |
| `test/services/payment_email_processor_service_test.rb` | Verifies end-to-end processing of real `.eml` files: HTML stripping, provider detection, tenant resolution (including aliases), utility matching, and rent fallbacks. |

### 6.3 Integration Tests

| Test File | Coverage |
|-----------|----------|
| `test/controllers/payment_emails_controller_test.rb` | Index filtering, show page |
| `test/controllers/email_configurations_controller_test.rb` | Edit, update, credential encryption |
| `test/controllers/notifications_controller_test.rb` | Index, mark as read |
| `test/integration/payment_ingestion_flow_test.rb` | End-to-end: email → parse → route → payment created |

### 6.4 Fixtures & EML Files

In addition to standard active record fixtures (Tenants, Leases, RentalProperties, Expenses, ScheduledRents), the test suite uses real production email samples saved as `.eml` files under `test/fixtures/emails/`:

* **`test/fixtures/emails/zelle-rent-payment.eml`** — Forwarded Chase Zelle rent payment.
* **`test/fixtures/emails/zelle-utility-payment.eml`** — Forwarded Chase Zelle utility payment.
* **`test/fixtures/emails/venmo-rent-payment.eml`** — Forwarded Venmo rent payment.

These raw files are read in tests to verify the Mail decoding, HTML-to-text extraction, regex pattern matching, and business routing logic:

```ruby
# Example test loader helper
def read_eml_fixture(filename)
  File.read(Rails.root.join("test/fixtures/emails", filename))
end
```

By verifying the parser and processor against the exact downloaded files, the test suite guarantees high reliability and prevents regressions on future layout updates.

---

## Migration Execution Order

1. `CreateTenantAliases` — new table
2. `CreateEmailConfigurations` — new table (per-user Gmail API credentials)
3. `CreatePaymentEmails` — new table
4. `CreateNotifications` — new table

---

## File Change Summary

| Action | Path |
|--------|------|
| **Create** | `db/migrate/XXXXX_create_tenant_aliases.rb` |
| **Create** | `db/migrate/XXXXX_create_email_configurations.rb` |
| **Create** | `db/migrate/XXXXX_create_payment_emails.rb` |
| **Create** | `db/migrate/XXXXX_create_notifications.rb` |
| **Create** | `app/models/tenant_alias.rb` |
| **Create** | `app/models/email_configuration.rb` |
| **Create** | `app/models/payment_email.rb` |
| **Create** | `app/models/notification.rb` |
| **Modify** | `app/models/tenant.rb` — add `has_many :tenant_aliases`, `all_names` method |
| **Modify** | `app/models/user.rb` — add `has_one :email_configuration` |
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
| 1 | **Authentication mechanism?** | **Multi-user Gmail API.** Each user stores their own OAuth credentials in the `email_configurations` table. Tokens are encrypted via Active Record Encryption. |
| 2 | **Payment provider coverage** | **Chase Bank (Zelle) and Venmo.** The parser uses provider-specific regex patterns for both sources, organized in a `PROVIDER_PATTERNS` lookup hash. |
| 3 | **Utility expense matching tolerance** | **Exact match.** The utility payment amount must exactly equal the expense amount — no tolerance. |
| 4 | **Forwarding mechanism** | **Both manual and auto-forwarded.** The system processes all unseen messages in the configured mailbox identically regardless of how they arrived. |
| 5 | **Notification on unmatched** | **In-app notification.** The system creates a `Notification` record visible from the dashboard with an unread badge in the header. No email notifications. |
