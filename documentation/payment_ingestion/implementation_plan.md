# Implementation Plan: Payment Ingestion

## Overview

A service library that ingests payment documents—individual receipts and multi-page bank statements—from multiple sources (PDF upload, and future email), extracts transaction data, resolves payers to tenants (supporting aliases for name/username mismatches), and creates `TenantPayment` records. The architecture cleanly supports adding new receipt sources (e.g., scheduled email fetching) and new document types without modifying the core ingestion logic.

### Goals

- Parse Chase Zelle and Venmo receipt PDFs to extract payment data.
- Parse multi-page Chase bank statements to extract Zelle and P2P ACH line items.
- Match payer names/usernames to tenants using an alias system for flexible lookup.
- Create `TenantPayment` records from parsed data.
- Design a source-agnostic ingestion pipeline so email receipts (and other sources) can reuse the same parsing and matching logic.
- Provide a UI for uploading documents and reviewing/confirming ingestion results before committing.

### Supported Document Types

| Document Type | Source | Parser | Notes |
|---|---|---|---|
| Chase Zelle receipt | PDF upload | `Parsers::Zelle` | Single-page, 1 payment per PDF |
| Venmo receipt | PDF upload | `Parsers::Venmo` | Single-page, 1 payment per PDF |
| Chase bank statement | PDF upload | `Parsers::ChaseStatement` | Multi-page, multiple Zelle/P2P payments per PDF |

### Test Fixtures

Sanitized test documents are in `test/fixtures/files/`:

| File | Source | Notes |
|------|--------|-------|
| `receipts/202604 Zelle.pdf` | Chase Zelle | Single-page receipt |
| `receipts/202403 Venmo.pdf` | Venmo | Single-page receipt |
| `receipts/202312 Security Deposit Zelle.pdf` | Chase Zelle | Single-page receipt |
| `statements/20260416-statements-1234-.pdf` | Chase statement | Multi-page, generated with mock data (no PII) |

### Design Decisions

| Question | Answer |
|----------|--------|
| How are payers matched to tenants? | By name/username lookup against `tenants.name` and a `tenant_aliases` table. |
| What if no tenant match is found? | Receipts are flagged `unmatched`; the user can manually assign via UI. Bank statement items with no match are silently discarded. |
| What if multiple tenants match? | The receipt is flagged `ambiguous`; the user picks the correct tenant. |
| Are records auto-committed? | No — uploaded documents produce reviewable records; the user confirms before `TenantPayment` records are created. |
| How are duplicates handled? | Compound unique index on `[payment_method, transaction_number]` on `tenant_payments`. Validation on `PaymentIngestion` warns/blocks if a payment already exists. |
| Storage strategy? | PDF files are stored as binary data (`bytea`) in the `payment_documents` table. Multiple `PaymentIngestion` records can share a single `PaymentDocument` (e.g., bank statement). |
| Timezone parsing? | User-configured timezone string on `users.timezone`. Receipts are parsed within this timezone context. |
| Name cleaning? | Parsers strip non-alphanumeric characters except typical name punctuation (spaces, apostrophes, hyphens, periods, underscores) and `@` handles. |
| Remember Alias checkbox? | Yes. The confirmation form includes an option to save the parsed payer name/username as an alias for the selected tenant. |
| PDF presentation? | For single receipts, the PDF is embedded in the review page. For bank statements, the extracted line item (`raw_text`) is displayed instead of the full multi-page PDF. |
| Failed parse manual correction? | If parsing fails, the landlord can manually fill out all fields and confirm anyway, preserving a complete audit trail. |

---

## Architecture

The ingestion pipeline follows a layered design: **sourcing** → **parsing** → **matching** → **recording**.

```
┌─────────────────────────────────────────────────────┐
│                   Document Sources                   │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐  │
│  │  PDF Upload  │  │ Email Fetch  │  │  Future…  │  │
│  │  (Phase 1)   │  │  (Phase 2)   │  │           │  │
│  └──────┬───────┘  └──────┬───────┘  └─────┬─────┘  │
│         │                 │                │         │
│         ▼                 ▼                ▼         │
│  ┌─────────────────────────────────────────────┐     │
│  │       PaymentIngestions::Ingestion          │     │
│  │  (orchestrator – user & source-agnostic)    │     │
│  │                                             │     │
│  │  1. Extract text via HexaPDF                │     │
│  │  2. Detect document type                    │     │
│  │  3. Delegate to appropriate parser          │     │
│  │  4. Resolve tenants via TenantResolver      │     │
│  │  5. Return PaymentIngestion record(s)       │     │
│  └─────────────────────────────────────────────┘     │
│         │                                            │
│         ▼                                            │
│  ┌─────────────────────────────────────────────┐     │
│  │        PaymentIngestions::Parsers            │     │
│  │  ┌───────────┐ ┌──────────┐ ┌────────────┐  │     │
│  │  │   Zelle   │ │  Venmo   │ │  Chase     │  │     │
│  │  │           │ │          │ │  Statement │  │     │
│  │  └───────────┘ └──────────┘ └────────────┘  │     │
│  └─────────────────────────────────────────────┘     │
│         │                                            │
│         ▼                                            │
│  ┌─────────────────────────────────────────────┐     │
│  │       PaymentIngestions::TenantResolver      │     │
│  │  (name/username → Tenant via aliases)        │     │
│  └─────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────┘
```

### Module Namespace

All ingestion code lives under `PaymentIngestions::` in `app/services/payment_ingestions/`:

```
app/services/
├── payment_ingestions.rb          # Error class hierarchy
└── payment_ingestions/
    ├── ingestion.rb               # Orchestrator
    ├── ingestion_result.rb        # Value object for parsed results
    ├── tenant_resolver.rb         # Name → Tenant matching
    └── parsers/
        ├── base.rb                # Common parser interface
        ├── zelle.rb               # Chase Zelle receipt parser
        ├── venmo.rb               # Venmo receipt parser
        └── chase_statement.rb     # Chase bank statement parser
```

---

## Database Schema

### `users` — Timezone Column

```ruby
add_column :users, :timezone, :string, default: "UTC", null: false
```

### `tenant_aliases`

Aliases allow flexible matching when receipt payer names differ from the tenant's name (e.g., Venmo handles or Zelle display names). Alias names are globally unique (case-insensitive).

```ruby
create_table :tenant_aliases do |t|
  t.references :tenant, null: false, foreign_key: true
  t.string     :alias_name, null: false
  t.timestamps
end

add_index :tenant_aliases, "lower(alias_name)", unique: true
```

### `payment_documents`

Stores the binary PDF file. Multiple `PaymentIngestion` records can reference the same document (e.g., when a bank statement contains multiple tenant transactions).

```ruby
create_table :payment_documents do |t|
  t.references :user, null: false, foreign_key: true
  t.binary     :attachment_file
  t.string     :attachment_filename
  t.string     :attachment_content_type
  t.timestamps
end
```

### `payment_ingestions`

Tracks each ingestion attempt for review, manual assignment, and auditing.

```ruby
create_table :payment_ingestions do |t|
  t.references :user, null: false, foreign_key: true
  t.references :tenant, foreign_key: true                     # null if unmatched
  t.references :lease, foreign_key: true                      # null if unresolved
  t.references :tenant_payment, foreign_key: true             # null until confirmed
  t.references :payment_document, foreign_key: true           # shared for statements

  t.string  :source, null: false                              # "pdf_upload", "email"
  t.string  :receipt_type                                     # "zelle", "venmo", "chase_statement"
  t.string  :status, null: false, default: "pending"          # pending, matched, unmatched, ambiguous, confirmed, failed
  t.string  :payer_name                                       # display name from document
  t.string  :payer_username                                   # username handle (e.g. Venmo @handle)
  t.decimal :amount, precision: 12, scale: 2
  t.date    :payment_date
  t.string  :payment_method                                   # "zelle", "venmo", "p2p"
  t.string  :transaction_number
  t.text    :raw_text                                         # full extracted text (receipt) or line item (statement)
  t.text    :error_message                                    # parsing error details

  t.timestamps
end
```

### `tenant_payments` — Unique Index

```ruby
add_index :tenant_payments, [:payment_method, :transaction_number], unique: true, where: "transaction_number IS NOT NULL"
```

---

## Models

### `TenantAlias`

```ruby
class TenantAlias < ApplicationRecord
  belongs_to :tenant

  validates :alias_name, presence: true
  validates :alias_name, uniqueness: { case_sensitive: false }

  normalizes :alias_name, with: ->(name) { name.strip }
end
```

### `PaymentDocument`

```ruby
class PaymentDocument < ApplicationRecord
  belongs_to :user
  has_many :payment_ingestions, dependent: :destroy

  validates :attachment_file, presence: true
  validates :attachment_filename, presence: true
  validates :attachment_content_type, presence: true
end
```

### `PaymentIngestion`

Handles parsing results, duplicate detection, confirmation flow, and alias creation.

```ruby
class PaymentIngestion < ApplicationRecord
  belongs_to :user
  belongs_to :tenant, optional: true
  belongs_to :lease, optional: true
  belongs_to :tenant_payment, optional: true
  belongs_to :payment_document, optional: true

  validates :source, presence: true
  validates :status, presence: true

  validate :ensure_not_duplicate_payment
  validate :validate_parse_status

  enum :status, {
    pending: "pending",
    matched: "matched",
    unmatched: "unmatched",
    ambiguous: "ambiguous",
    confirmed: "confirmed",
    failed: "failed"
  }

  PAYMENT_METHODS = [
    [ "Chase Zelle", "zelle" ],
    [ "Venmo", "venmo" ],
    [ "P2P", "p2p" ]
  ].freeze

  scope :reviewable, -> { where(status: [:matched, :unmatched, :ambiguous, :failed]) }

  def confirmable?
    tenant.present? && lease.present? && amount.present? && payment_date.present? && !duplicate_exists?
  end

  def confirm!(create_alias: false)
    # Creates a TenantPayment, optionally saves aliases, and marks status as confirmed
  end

  def duplicate_exists?
    # Checks TenantPayment table for existing payment_method + transaction_number combination
  end

  def ingestion_duplicate_exists?
    # Checks PaymentIngestion table for pending duplicate uploads
  end

  def attachment_attached?
    payment_document.present?
  end

  def attachment_image?
    payment_document&.attachment_content_type&.start_with?("image/")
  end
end
```

### `Tenant` — Additions

```ruby
has_many :tenant_aliases, dependent: :destroy
has_many :payment_ingestions
accepts_nested_attributes_for :tenant_aliases, allow_destroy: true, reject_if: :all_blank
```

---

## Service Library (`PaymentIngestions::`)

### Error Hierarchy

```ruby
module PaymentIngestions
  class Error < StandardError; end
  class ParsingError < Error; end
  class ResolutionError < Error; end
  class ConfirmationError < Error; end
end
```

### `PaymentIngestions::IngestionResult` (Value Object)

Captures parsed data from any parser, including `payer_username` for Venmo handles.

```ruby
module PaymentIngestions
  class IngestionResult
    attr_accessor :payer_name, :payer_username, :amount, :payment_date,
                  :payment_method, :transaction_number, :receipt_type,
                  :raw_text, :error_message, :success

    def success?
      !!success && error_message.nil?
    end
  end
end
```

### `PaymentIngestions::Parsers::Base`

Common parser interface with shared helpers for name cleaning, amount parsing, and date parsing.

```ruby
module PaymentIngestions
  module Parsers
    class Base
      def parse(pdf_text)
        raise NotImplementedError
      end

      private

      def clean_name(name)
        return nil if name.blank?
        name.gsub(/[^\p{Alnum}\p{Space}'\-._@]/, "").squish
      end

      def parse_amount(text)
        match = text.match(/\$\s*([\d,]+\.\d{2})/)
        return nil unless match
        BigDecimal(match[1].delete(","))
      end

      def parse_date(text)
        Time.zone.parse(text)&.to_date
      rescue ArgumentError, Date::Error
        nil
      end
    end
  end
end
```

### `PaymentIngestions::Parsers::Zelle`

Parses single-page Chase Zelle receipt PDFs. Extracts payer name, amount, date, and transaction number.

```ruby
module PaymentIngestions
  module Parsers
    class Zelle < Base
      def parse(pdf_text)
        IngestionResult.new(
          receipt_type: "zelle",
          payment_method: "zelle",
          raw_text: pdf_text,
          payer_name: clean_name(extract_payer(pdf_text)),
          payer_username: nil,
          amount: extract_amount(pdf_text),
          payment_date: extract_date(pdf_text),
          transaction_number: extract_transaction_id(pdf_text),
          success: true
        )
      rescue => e
        IngestionResult.new(receipt_type: "zelle", raw_text: pdf_text, error_message: e.message, success: false)
      end

      private

      def extract_payer(text)
        match = text.match(/Completed\s+([A-Za-z ]+?)\s+(?:In moments|Scheduled)/i)
        return match[1].strip if match
        match = text.match(/(.+?)\s+sent you money/i)
        match&.[](1)&.strip
      end

      def extract_amount(text)
        parse_amount(text)
      end

      def extract_date(text)
        match = text.match(/([a-zA-Z]{3}\s+\d{1,2},\s+\d{4})/i)
        return nil unless match
        parse_date(match[1].strip)
      end

      def extract_transaction_id(text)
        match = text.match(/Transaction number\s+(\S+)/i)
        match&.[](1)
      end
    end
  end
end
```

### `PaymentIngestions::Parsers::Venmo`

Parses single-page Venmo receipt PDFs. Extracts payer name, `@username`, amount, date, and transaction ID.

```ruby
module PaymentIngestions
  module Parsers
    class Venmo < Base
      def parse(pdf_text)
        IngestionResult.new(
          receipt_type: "venmo",
          payment_method: "venmo",
          raw_text: pdf_text,
          payer_name: clean_name(extract_payer(pdf_text)),
          payer_username: clean_name(extract_username(pdf_text)),
          amount: extract_amount(pdf_text),
          payment_date: extract_date(pdf_text),
          transaction_number: extract_transaction_id(pdf_text),
          success: true
        )
      rescue => e
        IngestionResult.new(receipt_type: "venmo", raw_text: pdf_text, error_message: e.message, success: false)
      end

      private

      def extract_payer(text)
        lines = text.split("\n").map(&:strip).reject(&:empty?)
        idx = lines.index("Transaction details")
        idx && lines[idx + 1] ? lines[idx + 1] : nil
      end

      def extract_username(text)
        match = text.match(/Received from\s+(@\S+)/i)
        match&.[](1)
      end

      def extract_amount(text)
        parse_amount(text)
      end

      def extract_date(text)
        match = text.match(/([a-zA-Z]{3}\s+\d{1,2},\s+\d{4},\s+\d{1,2}:\d{2}\s+(?:AM|PM))/i)
        return nil unless match
        parse_date(match[1].strip)
      end

      def extract_transaction_id(text)
        match = text.match(/Transaction ID\s+(\d+)/i)
        match&.[](1)
      end
    end
  end
end
```

### `PaymentIngestions::Parsers::ChaseStatement`

Parses multi-page Chase bank statements. Extracts Zelle and P2P ACH line items from the `TRANSACTION DETAIL` section.

- **Year inference:** Parses the statement period header (e.g., `"March 18, 2026 through April 16, 2026"`) to resolve `MM/DD` dates to the correct year, handling December–January rollovers.
- **Line item extraction:** Regex matching on each line for:
  - Zelle: `03/24  Zelle Payment From Alice Smith ZELNEW202604A  1,300.00  2,850.00`
  - P2P ACH: `04/01  Oak Vly Com Bnk  P2P  Bob Jones  Web ID: P2PNEW202604A  1,000.00  3,700.00`
- **`raw_text`:** Stores only the matched line item text (not the entire statement), making review cleaner.
- Returns an **array** of `IngestionResult` objects.

```ruby
module PaymentIngestions
  module Parsers
    class ChaseStatement < Base
      def parse(pdf_text)
        period_match = pdf_text.match(/([a-zA-Z]+\s+\d{1,2},\s+\d{4})\s+through\s+([a-zA-Z]+\s+\d{1,2},\s+\d{4})/i)
        start_date, end_date = if period_match
          [parse_date(period_match[1]), parse_date(period_match[2])]
        else
          [Date.current.beginning_of_year, Date.current]
        end

        results = []
        pdf_text.each_line do |line|
          line = line.strip
          next if line.empty?

          # Zelle match
          if (m = line.match(/^\s*(\d{2}\/\d{2})\s+Zelle Payment From\s+(.+?)\s+(\w+)\s+([\d,]+\.\d{2})\s+[\d,]+\.\d{2}\s*$/i))
            results << build_result("zelle", m, line, start_date, end_date)

          # P2P ACH match
          elsif (m = line.match(/^\s*(\d{2}\/\d{2})\s+(.+?\bP2P)\s+(.+?)\s+Web ID:\s*(\w+)\s+([\d,]+\.\d{2})\s+[\d,]+\.\d{2}\s*$/i))
            results << build_p2p_result(m, line, start_date, end_date)
          end
        end
        results
      rescue => e
        [IngestionResult.new(receipt_type: "chase_statement", raw_text: pdf_text, error_message: e.message, success: false)]
      end

      private

      def resolve_date(date_str, start_date, end_date)
        month, day = date_str.split("/").map(&:to_i)
        year = end_date.year
        d = Date.new(year, month, day)
        if d < start_date || d > end_date
          year = start_date.year
          d = Date.new(year, month, day)
        end
        d
      rescue Date::Error
        Date.current
      end
    end
  end
end
```

### `PaymentIngestions::TenantResolver`

Resolves a payer name or username against tenant names and aliases (case-insensitive).

```ruby
module PaymentIngestions
  class TenantResolver
    ResolveResult = Struct.new(:tenant, :tenants, :status, keyword_init: true)

    def resolve(user, display_name, username)
      return ResolveResult.new(status: :unmatched) if display_name.blank? && username.blank?

      candidates = find_candidates(user, display_name, username)

      case candidates.size
      when 0 then ResolveResult.new(status: :unmatched)
      when 1 then ResolveResult.new(tenant: candidates.first, tenants: candidates, status: :matched)
      else        ResolveResult.new(tenants: candidates, status: :ambiguous)
      end
    end

    private

    def find_candidates(user, display_name, username)
      results = []
      if username.present?
        normalized = username.strip.downcase
        results += user.tenants.where("LOWER(name) = ?", normalized).to_a
        results += user.tenants.joins(:tenant_aliases).where("LOWER(tenant_aliases.alias_name) = ?", normalized).to_a
      end
      if display_name.present?
        normalized = display_name.strip.downcase
        results += user.tenants.where("LOWER(name) = ?", normalized).to_a
        results += user.tenants.joins(:tenant_aliases).where("LOWER(tenant_aliases.alias_name) = ?", normalized).to_a
      end
      results.uniq
    end
  end
end
```

### `PaymentIngestions::Ingestion` (Orchestrator)

Coordinates the full ingestion pipeline. Handles both single-page receipts and multi-page bank statements.

**Key behaviors:**

- Runs parsing within the user's timezone context.
- Extracts text from all pages using `HexaPDF`.
- Detects document type (`chase_statement`, `venmo`, or `zelle`) based on text markers.
- For bank statements: creates one `PaymentDocument` shared by all resulting `PaymentIngestion` records; discards unmatched items silently.
- For receipts: creates one `PaymentDocument` + one `PaymentIngestion`.
- Returns an **Array** for statements, a single `PaymentIngestion` for receipts.

**Document type detection:**

| Marker | Type |
|--------|------|
| `CHASE TOTAL CHECKING` + `TRANSACTION DETAIL` | `chase_statement` |
| `Transaction ID` or `venmo` | `venmo` |
| `zelle` or `chase` or `Transaction number` | `zelle` |

---

## Controller & Routes

### Routes

```ruby
resources :payment_ingestions do
  member do
    post :confirm
    get :download
  end
end
```

### `PaymentIngestionsController`

| Action | Behavior |
|--------|----------|
| `index` | Lists reviewable (pending) and confirmed ingestion records |
| `new` | Upload form for receipts and statements |
| `create` | Calls `Ingestion` orchestrator; redirects to `show` (receipt) or `index` (statement) |
| `show` | Review page with tenant/lease assignment dropdowns (dynamically filtered via Stimulus) |
| `update` | Saves manual corrections; auto-promotes status to `matched` if confirmable |
| `confirm` | Creates `TenantPayment` via `confirm!`, optionally saves aliases |
| `download` | Streams the PDF from the associated `PaymentDocument` |
| `destroy` | Deletes the ingestion record |

**Tenant/Lease dynamic filtering:** The `show` action builds `tenant_leases_map` and `lease_tenants_map` hashes, passed to a Stimulus controller that keeps the tenant and lease dropdowns in sync—selecting a tenant filters leases to those associated with that tenant, and vice versa. All leases are shown regardless of payment status.

---

## Verification Plan

### Automated Tests

Run the full test suite:

```bash
bin/rails test
```

Key test files:

| File | Coverage |
|------|----------|
| `test/models/payment_ingestion_test.rb` | Model validations, confirmable logic, duplicate detection |
| `test/models/tenant_alias_test.rb` | Alias uniqueness and normalization |
| `test/controllers/payment_ingestions_controller_test.rb` | CRUD, statement upload, duplicate handling |
| `test/services/payment_ingestions_test.rb` | End-to-end ingestion for Zelle, Venmo, and bank statements; tenant resolution |
| `test/services/payment_ingestions/parsers/chase_statement_test.rb` | Statement parser regex matching, year inference |

### Manual Verification

- Upload the three receipt PDFs and the sanitized statement PDF through the web dashboard.
- Verify tenant matching/unmatching behavior.
- Confirm a matched item and inspect the resulting `TenantPayment` and balance updates.
- Upload a duplicate receipt to verify validation warnings and DB constraint behavior.
- For bank statements, verify multiple pending records appear in the index with individual line items.
