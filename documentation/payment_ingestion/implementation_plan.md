# Implementation Plan: Payment Receipt Ingestion

## Overview

Build a service library that ingests payment receipts from multiple sources (PDF files, and future email), extracts transaction data, resolves the payer to a tenant (supporting aliases for name/username mismatches), and creates `TenantPayment` records. The architecture must cleanly support adding new receipt sources (e.g., scheduled email fetching) without modifying the core ingestion logic.

### Goals

- Parse Zelle (Chase) and Venmo receipt PDFs to extract payment data.
- Match payer names/usernames to tenants using an alias system for flexible lookup.
- Create `TenantPayment` records from parsed receipt data.
- Design a source-agnostic ingestion pipeline so email receipts (and other sources) can reuse the same parsing and matching logic.
- Provide a UI for uploading receipts and reviewing/confirming ingestion results before committing.

### Receipt Fixtures

Three test PDFs are provided in `test/fixtures/files/receipts/`:

| File | Source | Notes |
|------|--------|-------|
| `202604 Zelle.pdf` | Chase Zelle | Title: "Payment Activity - chase.com" |
| `202403 Venmo.pdf` | Venmo | Title: "Transaction details" |
| `202312 Security Deposit Zelle.pdf` | Chase Zelle | Title: "Transfer activity - chase.com" |

### Decisions

| Question | Answer |
|----------|--------|
| How are payers matched to tenants? | By name/username lookup against `tenants.name` and a new `tenant_aliases` table. |
| What if no tenant match is found? | The receipt is flagged as `unmatched`; the user can manually assign it via UI. |
| What if multiple tenants match? | The receipt is flagged as `ambiguous`; the user picks the correct tenant. |
| Are receipts auto-committed? | No — uploaded receipts produce a reviewable record; the user confirms before creating `TenantPayment` records. |
| How are duplicate receipts handled? | Enforced by a compound unique index on `[payment_method, transaction_number]` on `tenant_payments`. Validation on `PaymentReceiptIngestion` warns/blocks if a payment already exists. |
| PDF scope? | Strictly 1 PDF upload maps to 1 payment for now. Multi-transaction statement PDFs are out of scope. |
| Future Email Scope? | User-scoped. The user will configure email inboxes to monitor for fetching emailed receipts. |
| Storage Strategy? | Receipt PDFs are stored as binary data in the database (`bytea` column) to avoid object store dependencies for this low-volume application (max ~3 tenants). Deleting the ingestion record deletes its associated binary; records are kept indefinitely for audit purposes (no auto-deletion). |
| Timezone parsing? | User-configured timezone string (defaulting to the user's timezone column on `users`). Receipts are parsed in this timezone context. |
| Name Cleaning? | Parsers strip non-alphanumeric characters except typical name punctuation (spaces, apostrophes, hyphens, periods, underscores) and `@` handles to avoid icon/unicode artifacts. |
| Remember Alias Checkbox? | Yes. The confirmation form includes an option to save the parsed payer name/username as an alias for the selected tenant on confirmation. |
| PDF Presentation? | Embedded inside the `show.html.erb` review page so the landlord can visually compare the PDF next to the form fields. |
| Failed Parse Manual Correction? | If parsing fails, the landlord can manually fill out all fields on the failed ingestion record and confirm it anyway, ensuring a complete audit trail. |

---

## Architecture

The ingestion pipeline follows a layered design that separates **sourcing** → **parsing** → **matching** → **recording**:

```
┌─────────────────────────────────────────────────────┐
│                   Receipt Sources                    │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐  │
│  │  PDF Upload  │  │ Email Fetch  │  │  Future…  │  │
│  │  (Phase 1)   │  │  (Phase 2)   │  │           │  │
│  └──────┬───────┘  └──────┬───────┘  └─────┬─────┘  │
│         │                 │                │         │
│         ▼                 ▼                ▼         │
│  ┌─────────────────────────────────────────────┐     │
│  │         PaymentReceipts::Ingestion          │     │
│  │  (orchestrator – user & source-agnostic)    │     │
│  │                                             │     │
│  │  1. Detect receipt type (Zelle vs Venmo)    │     │
│  │  2. Delegate to appropriate parser          │     │
│  │  3. Resolve tenant via TenantResolver       │     │
│  │  4. Return IngestionResult                  │     │
│  └─────────────────────────────────────────────┘     │
│         │                                            │
│         ▼                                            │
│  ┌─────────────────────────────────────────────┐     │
│  │         PaymentReceipts::Parsers            │     │
│  │  ┌───────────┐  ┌────────────┐              │     │
│  │  │   Zelle   │  │   Venmo    │              │     │
│  │  └───────────┘  └────────────┘              │     │
│  └─────────────────────────────────────────────┘     │
│         │                                            │
│         ▼                                            │
│  ┌─────────────────────────────────────────────┐     │
│  │         PaymentReceipts::TenantResolver     │     │
│  │  (name/username → Tenant via aliases)       │     │
│  └─────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────┘
```

### Module Namespace

All receipt ingestion code lives under `PaymentReceipts::` in `app/services/payment_receipts/`:

```
app/services/payment_receipts/
├── errors.rb                 # StandardError subclasses
├── ingestion.rb              # Orchestrator
├── ingestion_result.rb       # Value object for parsed results
├── tenant_resolver.rb        # Name → Tenant matching
└── parsers/
    ├── base.rb               # Common parser interface
    ├── zelle.rb              # Chase Zelle PDF parser
    └── venmo.rb              # Venmo PDF parser
```

---

## Phase 1 — Schema Changes

### 1.1 Add Timezone to `users`

```ruby
# db/migrate/XXXXXXXX_add_timezone_to_users.rb
class AddTimezoneToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :timezone, :string, default: "UTC", null: false
  end
end
```

### 1.2 New Table: `tenant_aliases`

Tenant aliases allow flexible matching when receipt payer names differ from the tenant's name (e.g., matching Venmo handles or Zelle names). Alias names must be globally unique case-insensitive.

```ruby
# db/migrate/XXXXXXXX_create_tenant_aliases.rb
create_table :tenant_aliases do |t|
  t.references :tenant, null: false, foreign_key: true
  t.string     :alias_name, null: false
  t.timestamps
end

add_index :tenant_aliases, "lower(alias_name)", unique: true
```

### 1.3 New Table: `payment_receipt_ingestions`

Tracks each ingestion attempt for review, manual assignment, and auditing. Stores the raw PDF as binary data (`bytea` in PostgreSQL).

```ruby
# db/migrate/XXXXXXXX_create_payment_receipt_ingestions.rb
create_table :payment_receipt_ingestions do |t|
  t.references :user, null: false, foreign_key: true
  t.references :tenant, foreign_key: true                # null if unmatched
  t.references :lease, foreign_key: true                 # null if unresolved
  t.references :tenant_payment, foreign_key: true        # null until confirmed

  t.string  :source, null: false                         # "pdf_upload", "email"
  t.string  :receipt_type                                # "zelle", "venmo"
  t.string  :status, null: false, default: "pending"     # pending, matched, unmatched, ambiguous, confirmed, failed
  t.string  :payer_name                                  # display name from receipt
  t.string  :payer_username                              # username handle (e.g. Venmo @handle)
  t.decimal :amount, precision: 12, scale: 2
  t.date    :payment_date
  t.string  :payment_method                              # "zelle", "venmo"
  t.string  :transaction_number
  t.text    :raw_text                                    # full extracted text
  t.text    :error_message                               # parsing error details
  t.binary  :pdf_file                                    # Raw PDF binary contents

  t.timestamps
end
```

### 1.4 Modify Table: `tenant_payments`

Add a compound unique index on `payment_method` and `transaction_number` to prevent duplicate ledger postings at the database level.

```ruby
# db/migrate/XXXXXXXX_add_unique_index_to_tenant_payments.rb
add_index :tenant_payments, [:payment_method, :transaction_number], unique: true, where: "transaction_number IS NOT NULL"
```

---

## Phase 2 — Model Changes

### 2.1 StandardError Hierarchy

We define explicit subclasses of `StandardError` to enable robust monitoring and categorisation:

```ruby
# app/services/payment_receipts/errors.rb
module PaymentReceipts
  class Error < StandardError; end
  class ParsingError < Error; end
  class ResolutionError < Error; end
  class ConfirmationError < Error; end
end
```

### 2.2 New Model: `TenantAlias`

```ruby
# app/models/tenant_alias.rb
class TenantAlias < ApplicationRecord
  belongs_to :tenant

  validates :alias_name, presence: true
  validates :alias_name, uniqueness: { case_sensitive: false }

  normalizes :alias_name, with: ->(name) { name.strip }
end
```

### 2.3 New Model: `PaymentReceiptIngestion`

Handles parsing failures as validation errors on the record during saving, meaning if a parsing error occurs during upload, the record fails to save and displays validation errors. If saved manually later, status validations are soft.

```ruby
# app/models/payment_receipt_ingestion.rb
class PaymentReceiptIngestion < ApplicationRecord
  belongs_to :user
  belongs_to :tenant, optional: true
  belongs_to :lease, optional: true
  belongs_to :tenant_payment, optional: true

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

  scope :reviewable, -> { where(status: [:matched, :unmatched, :ambiguous, :failed]) }

  def confirmable?
    tenant.present? && lease.present? && amount.present? && payment_date.present? && !duplicate_exists?
  end

  def confirm!(create_alias: false)
    raise PaymentReceipts::ConfirmationError, "Cannot confirm: missing required fields or duplicate exists" unless confirmable?
    raise PaymentReceipts::ConfirmationError, "Already confirmed" if confirmed?

    transaction do
      # Note: uses current attributes on the ingestion record (which may have been edited by the user)
      payment = TenantPayment.create!(
        lease: lease,
        amount: amount,
        payment_date: payment_date,
        payment_method: payment_method,
        transaction_number: transaction_number
      )

      if create_alias
        # Create alias for payer name if it's not already matched and is not the tenant's canonical name
        if payer_name.present? && payer_name.downcase != tenant.name.downcase && !tenant.tenant_aliases.exists?(alias_name: payer_name)
          tenant.tenant_aliases.create!(alias_name: payer_name)
        end
        # Create alias for payer username if it's not already matched
        if payer_username.present? && !tenant.tenant_aliases.exists?(alias_name: payer_username)
          tenant.tenant_aliases.create!(alias_name: payer_username)
        end
      end

      update!(status: :confirmed, tenant_payment: payment)
      payment
    end
  rescue ActiveRecord::RecordNotUnique
    raise PaymentReceipts::ConfirmationError, "This transaction has already been recorded in another tenant payment."
  end

  def duplicate_exists?
    return false if transaction_number.blank? || payment_method.blank?
    TenantPayment.exists?(payment_method: payment_method, transaction_number: transaction_number)
  end

  private

  def validate_parse_status
    # We only surface validation errors for parsing errors on new records before saving.
    # If the landlord manually edits a failed parser record to make it valid, we clear errors.
    if failed? && error_message.present? && amount.blank? && tenant.blank?
      errors.add(:base, "Parsing failed: #{error_message}")
    end
  end

  def ensure_not_duplicate_payment
    if duplicate_exists?
      errors.add(:transaction_number, "has already been recorded in a tenant payment")
    end
  end
end
```

### 2.4 Modified: `Tenant`

```ruby
# app/models/tenant.rb — additions
has_many :tenant_aliases, dependent: :destroy
has_many :payment_receipt_ingestions

accepts_nested_attributes_for :tenant_aliases, allow_destroy: true, reject_if: :all_blank
```

---

## Phase 3 — Service Library (`PaymentReceipts::`)

### 3.1 `PaymentReceipts::IngestionResult` (Value Object)

We add `payer_username` to capture handles like `@shoppetheivy` on Venmo.

```ruby
# app/services/payment_receipts/ingestion_result.rb
module PaymentReceipts
  class IngestionResult
    attr_accessor :payer_name, :payer_username, :amount, :payment_date, 
                  :payment_method, :transaction_number, :receipt_type, 
                  :raw_text, :error_message, :success

    def initialize(attrs = {})
      attrs.each { |k, v| send(:"#{k}=", v) }
    end

    def success?
      !!success && error_message.nil?
    end

    def to_h
      {
        payer_name: payer_name,
        payer_username: payer_username,
        amount: amount,
        payment_date: payment_date,
        payment_method: payment_method,
        transaction_number: transaction_number,
        receipt_type: receipt_type,
        raw_text: raw_text,
        error_message: error_message
      }
    end
  end
end
```

### 3.2 `PaymentReceipts::Parsers::Base`

Cleans extracted names to strip out emojis, Chase icons, and unrecognized symbols while keeping standard name punctuation, spaces, and handles.

```ruby
# app/services/payment_receipts/parsers/base.rb
module PaymentReceipts
  module Parsers
    class Base
      def parse(pdf_text)
        raise NotImplementedError, "#{self.class}#parse must be implemented"
      end

      private

      def clean_name(name)
        return nil if name.blank?
        # Keep letters, numbers, spaces, apostrophes, hyphens, periods, underscores, and @
        name.gsub(/[^\p{Alnum}\p{Space}'\-._@]/, '').squish
      end

      def parse_amount(text)
        match = text.match(/\$\s*([\d,]+\.\d{2})/)
        return nil unless match
        BigDecimal(match[1].delete(","))
      end

      def parse_date(text)
        # Parse within the active Time.zone context
        Time.zone.parse(text)&.to_date
      rescue ArgumentError, Date::Error
        nil
      end
    end
  end
end
```

### 3.3 `PaymentReceipts::Parsers::Zelle`

```ruby
# app/services/payment_receipts/parsers/zelle.rb
module PaymentReceipts
  module Parsers
    class Zelle < Base
      def parse(pdf_text)
        raw_payer = extract_payer(pdf_text)
        IngestionResult.new(
          receipt_type: "zelle",
          payment_method: "zelle",
          raw_text: pdf_text,
          payer_name: clean_name(raw_payer),
          payer_username: nil,
          amount: extract_amount(pdf_text),
          payment_date: extract_date(pdf_text),
          transaction_number: extract_transaction_id(pdf_text),
          success: true
        )
      rescue => e
        IngestionResult.new(
          receipt_type: "zelle",
          raw_text: pdf_text,
          error_message: e.message,
          success: false
        )
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

### 3.4 `PaymentReceipts::Parsers::Venmo`

```ruby
# app/services/payment_receipts/parsers/venmo.rb
module PaymentReceipts
  module Parsers
    class Venmo < Base
      def parse(pdf_text)
        raw_payer = extract_payer(pdf_text)
        raw_username = extract_username(pdf_text)
        IngestionResult.new(
          receipt_type: "venmo",
          payment_method: "venmo",
          raw_text: pdf_text,
          payer_name: clean_name(raw_payer),
          payer_username: clean_name(raw_username),
          amount: extract_amount(pdf_text),
          payment_date: extract_date(pdf_text),
          transaction_number: extract_transaction_id(pdf_text),
          success: true
        )
      rescue => e
        IngestionResult.new(
          receipt_type: "venmo",
          raw_text: pdf_text,
          error_message: e.message,
          success: false
        )
      end

      private

      def extract_payer(text)
        lines = text.split("\n").map(&:strip).reject(&:empty?)
        idx = lines.index("Transaction details")
        if idx && lines[idx + 1]
          lines[idx + 1]
        else
          nil
        end
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

### 3.5 `PaymentReceipts::TenantResolver`

Resolves a payer name or username against tenant names and aliases.

```ruby
# app/services/payment_receipts/tenant_resolver.rb
module PaymentReceipts
  class TenantResolver
    ResolveResult = Struct.new(:tenant, :tenants, :status, keyword_init: true)

    def resolve(user, display_name, username)
      return ResolveResult.new(status: :unmatched) if display_name.blank? && username.blank?

      candidates = find_candidates(user, display_name, username)

      case candidates.size
      when 0
        ResolveResult.new(status: :unmatched)
      when 1
        ResolveResult.new(tenant: candidates.first, tenants: candidates, status: :matched)
      else
        ResolveResult.new(tenants: candidates, status: :ambiguous)
      end
    end

    private

    def find_candidates(user, display_name, username)
      results = []

      # Try matching by username if present (e.g. "@handle")
      if username.present?
        normalized_username = username.strip.downcase
        results += user.tenants.where("LOWER(name) = ?", normalized_username).to_a
        results += user.tenants.joins(:tenant_aliases).where("LOWER(tenant_aliases.alias_name) = ?", normalized_username).to_a
      end

      if display_name.present?
        normalized_name = display_name.strip.downcase
        results += user.tenants.where("LOWER(name) = ?", normalized_name).to_a
        results += user.tenants.joins(:tenant_aliases).where("LOWER(tenant_aliases.alias_name) = ?", normalized_name).to_a
      end

      results.uniq
    end
  end
end
```

### 3.6 `PaymentReceipts::Ingestion` (Orchestrator)

Runs parsing inside the user's timezone context.

```ruby
# app/services/payment_receipts/ingestion.rb
module PaymentReceipts
  class Ingestion
    PARSERS = {
      "zelle" => Parsers::Zelle,
      "venmo" => Parsers::Venmo
    }.freeze

    def call(user:, pdf_path_or_io:, source: "pdf_upload")
      # Extract text and run parsing in the user's local timezone context
      Time.use_zone(user.timezone) do
        pdf_bytes = read_pdf_bytes(pdf_path_or_io)
        raw_text = extract_text(pdf_path_or_io)
        receipt_type = detect_type(raw_text)
        parser = (PARSERS[receipt_type] || Parsers::Zelle).new
        result = parser.parse(raw_text)

        ingestion = if result.success?
          resolve_result = TenantResolver.new.resolve(user, result.payer_name, result.payer_username)
          tenant = resolve_result.tenant
          lease = tenant&.leases&.find { |l| active_lease?(l, result.payment_date) }

          PaymentReceiptIngestion.new(
            user: user,
            source: source,
            receipt_type: result.receipt_type,
            status: resolve_result.status,
            payer_name: result.payer_name,
            payer_username: result.payer_username,
            amount: result.amount,
            payment_date: result.payment_date,
            payment_method: result.payment_method,
            transaction_number: result.transaction_number,
            raw_text: result.raw_text,
            tenant: tenant,
            lease: lease,
            pdf_file: pdf_bytes
          )
        else
          PaymentReceiptIngestion.new(
            user: user,
            source: source,
            receipt_type: receipt_type,
            status: :failed,
            raw_text: raw_text,
            error_message: result.error_message,
            pdf_file: pdf_bytes
          )
        end

        ingestion.save
        ingestion
      end
    end

    private

    def read_pdf_bytes(pdf_path_or_io)
      if pdf_path_or_io.respond_to?(:read)
        pdf_path_or_io.rewind
        bytes = pdf_path_or_io.read
        pdf_path_or_io.rewind
        bytes
      else
        File.binread(pdf_path_or_io.to_s)
      end
    end

    def extract_text(pdf_path_or_io)
      require "hexapdf"

      doc = if pdf_path_or_io.respond_to?(:read)
        HexaPDF::Document.new(io: pdf_path_or_io)
      else
        HexaPDF::Document.open(pdf_path_or_io.to_s)
      end

      # Strictly enforce 1-page/1-payment checks
      raise PaymentReceipts::ParsingError, "Multi-page statement PDFs are not supported" if doc.pages.count > 1

      page = doc.pages.first
      extractor = doc.task(:smart_text_extractor) rescue nil
      
      if extractor
        extractor.text(page)
      else
        page.extract_text rescue ""
      end
    end

    def detect_type(text)
      case text
      when /venmo/i then "venmo"
      when /zelle/i, /chase/i then "zelle"
      else "unknown"
      end
    end

    def active_lease?(lease, payment_date)
      return true if lease.month_to_month?
      return true unless lease.termination_date
      date = payment_date || Date.current
      date >= lease.commencement_date && date <= lease.termination_date
    end
  end
end
```

---

## Phase 4 — Controller & Route Changes

### 4.1 New Controller: `PaymentReceiptIngestionsController`

Handles PDF upload, review of parsed results, and confirmation.

```ruby
# app/controllers/payment_receipt_ingestions_controller.rb
class PaymentReceiptIngestionsController < ApplicationController
  before_action :set_ingestion, only: [:show, :update, :confirm, :destroy, :download]

  # GET /payment_receipt_ingestions
  def index
    @ingestions = current_user.payment_receipt_ingestions.order(created_at: :desc)
    @pending = @ingestions.where(status: [:matched, :unmatched, :ambiguous, :failed])
  end

  # GET /payment_receipt_ingestions/:id
  def show
  end

  # GET /payment_receipt_ingestions/new
  def new
    @ingestion = PaymentReceiptIngestion.new
  end

  # GET /payment_receipt_ingestions/:id/download
  def download
    if @ingestion.pdf_file.present?
      send_data @ingestion.pdf_file,
        filename: "receipt_#{@ingestion.id}.pdf",
        type: "application/pdf",
        disposition: "inline"
    else
      redirect_to payment_receipt_ingestion_path(@ingestion), alert: "No PDF file attached to this ingestion."
    end
  end

  # POST /payment_receipt_ingestions
  def create
    uploaded_file = params[:receipt_file]

    unless uploaded_file&.content_type == "application/pdf"
      @ingestion = PaymentReceiptIngestion.new
      @ingestion.errors.add(:base, "Please upload a PDF file.")
      render :new, status: :unprocessable_entity
      return
    end

    begin
      @ingestion = PaymentReceipts::Ingestion.new.call(
        user: current_user,
        pdf_path_or_io: uploaded_file.tempfile,
        source: "pdf_upload"
      )

      if @ingestion.persisted?
        redirect_to payment_receipt_ingestion_path(@ingestion),
          notice: ingestion_flash_message(@ingestion)
      else
        render :new, status: :unprocessable_entity
      end
    rescue PaymentReceipts::ParsingError => e
      @ingestion = PaymentReceiptIngestion.new
      @ingestion.errors.add(:base, e.message)
      render :new, status: :unprocessable_entity
    end
  end

  # PATCH /payment_receipt_ingestions/:id
  def update
    if @ingestion.update(ingestion_update_params)
      # If manual corrections make it confirmable, mark as matched so confirmation button appears
      if @ingestion.confirmable? && !@ingestion.confirmed?
        @ingestion.update!(status: :matched)
      end
      redirect_to payment_receipt_ingestion_path(@ingestion),
        notice: "Ingestion details updated."
    else
      render :show, status: :unprocessable_entity
    end
  end

  # POST /payment_receipt_ingestions/:id/confirm
  def confirm
    create_alias = ActiveModel::Type::Boolean.new.cast(params[:create_alias])
    payment = @ingestion.confirm!(create_alias: create_alias)
    
    redirect_to payment_receipt_ingestion_path(@ingestion),
      notice: "Payment of #{helpers.number_to_currency(payment.amount)} created successfully."
  rescue PaymentReceipts::ConfirmationError => e
    redirect_to payment_receipt_ingestion_path(@ingestion),
      alert: "Could not confirm: #{e.message}"
  end

  # DELETE /payment_receipt_ingestions/:id
  def destroy
    @ingestion.destroy!
    redirect_to payment_receipt_ingestions_path,
      notice: "Ingestion record deleted."
  end

  private

  def set_ingestion
    @ingestion = current_user.payment_receipt_ingestions.find(params[:id])
  end

  def ingestion_update_params
    params.expect(payment_receipt_ingestion: [:tenant_id, :lease_id, :amount, :payment_date, :payment_method, :transaction_number])
  end

  def ingestion_flash_message(ingestion)
    case ingestion.status
    when "matched"  then "Receipt parsed and tenant matched! Review and confirm below."
    when "unmatched" then "Receipt parsed but no tenant match found. Please assign a tenant."
    when "ambiguous" then "Receipt parsed but multiple tenants matched. Please select the correct one."
    when "failed"    then "Could not parse this receipt. #{ingestion.error_message}"
    else "Receipt uploaded."
    end
  end
end
```

### 4.2 Route Changes

```ruby
# config/routes.rb — additions
resources :payment_receipt_ingestions, only: [:index, :new, :create, :show, :update, :destroy] do
  member do
    post :confirm
    get :download
  end
end
```

---

## Phase 5 — Verification Plan

### Automated Tests
We run the suite and verify the extraction and resolution logic passes correctly:
- `rails test test/services/payment_receipts/`
- `rails test test/models/tenant_alias_test.rb`
- `rails test test/controllers/payment_receipt_ingestions_controller_test.rb`

### Manual Verification
- Upload the three PDFs located in `test/fixtures/files/receipts/` through the web dashboard, verifying they resolve to matched or unmatched candidates accordingly.
- Confirm one matching item and inspect the resulting balance updates.
- Upload a duplicate receipt to verify validation warnings and DB constraint behavior.
