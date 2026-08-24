# Double-Entry Accounting Engine Architecture

## Overview

Yanushi features an immutable, append-only, ledger-backed double-entry accounting engine. All financial activities across the application—tenant charges, rental receipts, property expenses, security deposit custody, and document ingestion—are recorded through balanced journal entries and postings.

This document serves as the authoritative technical reference for the accounting subsystem, its boundaries with domain modules, its reporting projections, and the lifecycle of financial events.

---

## 1. Domain vs. Accounting Boundaries

Yanushi enforces a strict separation of concerns between **domain modules** and the **accounting ledger**:

```
+-----------------------------------------------------------------------------------+
|                                DOMAIN LAYER                                       |
|  Property | RentableUnit | Party | Tenancy | RentTerm | Charge | Receipt | Expense  |
|  SecurityDeposit | SourceDocument | ImportedTransaction                           |
|  - Encapsulates domain logic, lifecycles, validations, and user workflows.        |
|  - Manages domain state (e.g. voided_at, superseded_by_id, status).               |
+-----------------------------------------------------------------------------------+
                                         |
                                         | Emits Domain Events via Services
                                         v
+-----------------------------------------------------------------------------------+
|                              ACCOUNTING LAYER                                     |
|  Accounting::PostEntryService | Accounting::PostingBuilder | ReverseEntryService  |
|  - Validates dimension hierarchies, account ownership, and balanced sums.         |
|  - Enforces idempotency via (user_id, source_type, source_id, event_type).        |
+-----------------------------------------------------------------------------------+
                                         |
                                         | Writes Immutable Ledger Rows
                                         v
+-----------------------------------------------------------------------------------+
|                              LEDGER STORAGE                                       |
|  Account | JournalEntry | Posting                                                 |
|  - Immutable, append-only database tables.                                        |
|  - before_update and before_destroy callbacks abort any modification.             |
|  - DB constraints enforce non-zero lines and valid account types.                 |
+-----------------------------------------------------------------------------------+
```

### Key Principles
- **Domain models never directly mutate ledger rows.** All ledger operations occur through dedicated domain services (`RentCharges::GenerateThroughService`, `Receipts::CreateService`, `Expenses::CreateService`, `SecurityDepositTransactions::ReceiveService`, etc.) delegating to `Accounting::PostEntryService`.
- **Ledger records are immutable.** `JournalEntry` and `Posting` tables lack `updated_at` columns and abort update/destroy operations. Corrections are made solely by posting linked reversal entries.
- **Foreign Key Protection.** Accounting postings maintain foreign keys with `on_delete: :restrict` against dimension records (`properties`, `rentable_units`, `tenancies`, `parties`) to prevent orphaned ledger history.
- **Balance & Integrity Enforcement.** Database check constraints enforce individual posting rules (non-zero `amount_cents` and valid account types). Cross-row journal balance (sum of all posting `amount_cents` equals zero) and dimension integrity are enforced at the service boundary by `Accounting::PostingBuilder` and `Accounting::PostEntryService`.

---

## 2. Debit/Credit Sign Convention

Yanushi represents double-entry amounts using signed 64-bit integers (`amount_cents`):

- **Debit (Dr):** Positive (`amount_cents > 0`)
- **Credit (Cr):** Negative (`amount_cents < 0`)

### Invariants
1. **Non-Zero Amounts:** Every posting must have a non-zero amount (`check_postings_amount_cents_nonzero`: `amount_cents <> 0`).
2. **Zero-Sum Balance:** Every `JournalEntry` must balance exactly to zero (`sum(amount_cents) == 0`), validated by `Accounting::PostingBuilder`.
3. **Natural Balances:** For user-facing display and financial reports, `Accounting::NaturalBalance` converts raw signed balances according to the account type:
   - **Asset:** Normal Debit (`+ = Dr`)
   - **Liability:** Normal Credit (`+ = Cr`)
   - **Equity:** Normal Credit (`+ = Cr`)
   - **Income:** Normal Credit (`+ = Cr`)
   - **Expense:** Normal Debit (`+ = Dr`)

---

## 3. Chart of Accounts

Every user is automatically provisioned with standard system accounts via `Accounting::ChartOfAccounts.ensure_for(user)` upon user creation:

| Account Key | Account Name | Account Type | Normal Balance | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `cash` | Cash | `asset` | Debit | Operating cash and bank accounts |
| `tenant_receivable` | Tenant Receivable | `asset` | Debit | Outstanding tenant debts and charges |
| `security_deposits_held` | Security Deposits Held | `liability` | Credit | Custodial tenant security deposit liabilities |
| `rental_income` | Rental Income | `income` | Credit | Scheduled and received rent |
| `late_fee_income` | Late Fee Income | `income` | Credit | Assessed tenant late fees |
| `reimbursement_income` | Reimbursement Income | `income` | Credit | Tenant-billed utility or repair reimbursements |
| `other_tenant_income` | Other Tenant Income | `income` | Credit | Miscellaneous tenant charges |
| `expense_advertising` | Advertising | `expense` | Debit | Marketing and leasing advertisements |
| `expense_auto_travel` | Auto and Travel | `expense` | Debit | Travel and vehicle expenses |
| `expense_cleaning_maintenance` | Cleaning and Maintenance | `expense` | Debit | Routine cleaning and maintenance |
| `expense_commissions` | Commissions | `expense` | Debit | Leasing and agent commissions |
| `expense_insurance` | Insurance | `expense` | Debit | Property and liability insurance |
| `expense_legal_professional` | Legal and Professional | `expense` | Debit | Legal, accounting, and professional fees |
| `expense_management` | Management | `expense` | Debit | Property management fees |
| `expense_mortgage_interest` | Mortgage Interest | `expense` | Debit | Mortgage interest paid to financial institutions |
| `expense_other_interest` | Other Interest | `expense` | Debit | Other interest on property loans/credit |
| `expense_repairs` | Repairs | `expense` | Debit | Property repairs and maintenance |
| `expense_supplies` | Supplies | `expense` | Debit | Office and property supplies |
| `expense_taxes` | Taxes | `expense` | Debit | Property and local real estate taxes |
| `expense_utilities` | Utilities | `expense` | Debit | Water, gas, electric, trash utilities |
| `expense_other` | Other Expense | `expense` | Debit | Miscellaneous operating expenses |
| `opening_balance_equity` | Opening Balance Equity | `equity` | Credit | Initial account setup and historical balances |

The `Account` model can represent additional custom accounts, but the platform does not expose a user-configurable chart-of-accounts workflow; all operations utilize the standard system accounts.

---

## 4. Posting Rules for Domain Modules

### 4.1 Charges (`Charge`)
Charges represent obligations billed to a tenancy.

| Event Type | Debits (Dr) | Credits (Cr) | Dimensions |
| :--- | :--- | :--- | :--- |
| `charge_posted` (Rent) | `tenant_receivable` (+amount) | `rental_income` (-amount) | Tenancy, Unit, Property |
| `charge_posted` (Late Fee) | `tenant_receivable` (+amount) | `late_fee_income` (-amount) | Tenancy, Unit, Property |
| `charge_posted` (Reimbursement) | `tenant_receivable` (+amount) | `reimbursement_income` (-amount) | Tenancy, Unit, Property |
| `charge_posted` (Other) | `tenant_receivable` (+amount) | `other_tenant_income` (-amount) | Tenancy, Unit, Property |

- **Voiding & Corrections:** Voiding a charge reverses its original `charge_posted` journal entry through `Accounting::ReverseEntryService` (`event_type: "reversal"`). Correcting a charge atomically reverses the original entry, marks the old charge voided/superseded, and creates the replacement charge and journal entry in a single database transaction.

### 4.2 Receipts (`Receipt`)
Receipts represent cash payments received from tenants or third-party payers.

| Event Type | Debits (Dr) | Credits (Cr) | Dimensions |
| :--- | :--- | :--- | :--- |
| `receipt_posted` | `cash` (+amount) | `tenant_receivable` (-amount) | Tenancy, Unit, Property, Party |

### 4.3 Expenses (`Expense`)
Expenses represent vendor payments made for property operations.

| Event Type | Debits (Dr) | Credits (Cr) | Dimensions |
| :--- | :--- | :--- | :--- |
| `expense_posted` | `expense_*` account (+amount) | `cash` (-amount) | Property, optional Unit |

- **Reimbursement Generation:** When an expense is marked reimbursable, `Charges::CreateReimbursementService` creates an associated `Charge` linked to the source expense.
- **Voiding & Corrections:** Voiding creates a reversal `JournalEntry`. Correcting an expense atomically reverses the original entry, marks the old expense superseded, and creates the replacement expense and journal entry in a single database transaction.

### 4.4 Security Deposits (`SecurityDepositTransaction`)
Security deposits are tracked as custodial liabilities, completely separated from rental revenue.

| Event Type | Debits (Dr) | Credits (Cr) | Dimensions |
| :--- | :--- | :--- | :--- |
| `deposit_received` | `cash` (+amount) | `security_deposits_held` (-amount) | Tenancy, Unit, Property, Party |
| `deposit_refunded` | `security_deposits_held` (+amount) | `cash` (-amount) | Tenancy, Unit, Property, Party |
| `deposit_applied` | `security_deposits_held` (+amount) | `tenant_receivable` (-amount) | Tenancy, Unit, Property |

---

## 5. Source-Event Idempotency

Yanushi enforces strict idempotency at the database and service layers:

1. **Composite Unique Index:** `idx_journal_entries_source_event` on `(user_id, source_type, source_id, event_type)` ensures each domain event posts at most once.
2. **Payload Verification:** `Accounting::PostEntryService` checks if an entry already exists for the given source event:
   - If the existing postings match the requested payload exactly, the existing entry is returned successfully (idempotent no-op).
   - If the existing postings differ, the service aborts with `:idempotency_conflict` to prevent silent corruption.
3. **Concurrency Protection:** Database uniqueness violations (`ActiveRecord::RecordNotUnique`) during concurrent execution are caught and resolved cleanly by fetching the committed entry.

---

## 6. Corrections and Reversals

In an append-only ledger, mistakes are corrected by reversing the original journal entry:

1. **Atomic Lineage Tracking:** `Accounting::ReverseEntryService` posts a new `JournalEntry` with `event_type: "reversal"` and `reversal_of_id` referencing the original entry.
2. **Single Reversal Constraint:** A partial unique index (`idx_journal_entries_single_reversal` where `reversal_of_id IS NOT NULL`) guarantees that an entry can be reversed at most once.
3. **Exact Inverse Postings:** The reversal entry duplicates all postings and dimension hierarchies from the original entry, exactly negating each `amount_cents` (`amount_cents * -1`).
4. **Reversal Invariants:**
   - Reversing a reversal is strictly prohibited (`ArgumentError`).
   - Reversal entries must have a valid `reversal_of_id` (`validates :reversal_of_id, presence: true, if: -> { event_type == "reversal" }`).
   - Tax reporting derives tax treatment from the original entry's lineage rather than reviewing reversals independently.

---

## 7. Running-Account Semantics

Tenancies in Yanushi use a **ledger-backed running balance** model:

- **No Static Balance Columns:** `Tenancy` does not store a balance column or direct links between payments and individual rent charges.
- **Dynamic Balance Calculation:** A tenancy's current balance is the sum of all postings to `tenant_receivable` dimensioned to that `tenancy_id`:
  ```text
  Tenancy Balance = Sum of postings where account == "tenant_receivable" and tenancy_id == T
  ```
  - **Balance > 0:** The tenant owes money (outstanding balance).
  - **Balance = 0:** The tenant is fully settled.
  - **Balance < 0:** The tenant has an overpayment / credit.
- **Point-in-Time Queries:** `Accounting::AccountBalanceQuery` and `Accounting::ActivityProjector` compute balances as of any historical timestamp or date range.

---

## 8. Security Deposit Accounting

Security deposits represent tenant funds held in trust:

- **Liability Tracking:** Security deposits are credited to `security_deposits_held` (a liability), not income.
- **Custody Reconciliation:** A tenancy's security deposit balance is derived from postings against `security_deposits_held` for that tenancy.
- **Charge Settlement:** When a security deposit is applied to unpaid rent or damages, `deposit_applied` reduces `security_deposits_held` (Dr) and credits `tenant_receivable` (Cr), extinguishing the tenant's debt without cash movement.

---

## 9. Accounting vs. Schedule E Tax Reporting Basis

Yanushi cleanly decouples operational accounting from IRS tax reporting:

```
+------------------------------------+       +------------------------------------+
|       GENERAL LEDGER (GL)          |       |     SCHEDULE E TAX REPORTING       |
| - Accrual-oriented domain events   | ----> | - Cash-basis rental income (Line 3)|
| - Rent charges recognized on due   |       | - Standardized expense lines       |
| - Unpaid charges increase A/R      |       | - Explicit manual review workflows |
+------------------------------------+       +------------------------------------+
```

### Core Tax Reporting Primitives (`TaxReporting` Module)
- **`PropertyTaxProfile`:** Captures year-specific IRS Schedule E property type classifications (Codes 1–5, 7–8: Single-Family Residence, Multi-Family Residence, Vacation / Short-Term Rental, Commercial, Land, Self-Rental, Other) scoped by `(property_id, tax_year)`. Royalties (Code 6) are intentionally unsupported.
- **`ScheduleEAccountMap`:** Maps Chart of Accounts system expense keys to IRS Schedule E categories (Lines 5–19).
- **`ScheduleEQuery`:**
  - **Line 3 (Rents Received):** Sourced automatically from positive cash inflows from ordinary `Receipt` postings in the tax year. In addition, otherwise-reviewable events (such as `deposit_applied` non-cash security deposit settlements or unrecognized income events) enter Line 3 only when granted an explicit `include_in_rents` tax review resolution by the user. Excludes unpaid rent charges, security deposit receipts, and operational transfers.
  - **Reversals:** Reversal entries derive their tax treatment directly from the original entry's resolution lineage.
  - **Expense Lines:** Mapped expense postings aggregate into their corresponding Schedule E lines (Lines 5–19).
  - **Review Gating & Resolutions (`PropertyTaxReviewResolution`):**
    - Unrecognized financial events, security deposit applications (`deposit_applied`), and unmapped custom expenses require explicit user tax review.
    - Resolutions are property-scoped (`property_id`, `tax_year`, `journal_entry_id`) with options to `include_in_rents`, `map_to_schedule_e_category`, or `exclude`.
    - Entries with multiple distinct unmapped expense accounts for the same property strictly **fail closed** (zero tax effect, listed as unresolved review items, blocking PDF export until resolved).
  - **Line 19 Statement:** Generates a paginated attached statement for itemized "Other Expenses".

---

## 10. How to Safely Add a New Financial Event

When introducing a new financial event type into Yanushi, complete this architectural checklist:

1. **Domain Source:** What domain model owns the event? (Must be an `ApplicationRecord` with an `id`).
2. **Event Type Identifier:** Choose a descriptive snake_case `event_type` string (e.g. `utility_refund_posted`).
3. **Account Movements (Debits & Credits):**
   - Which accounts increase/decrease?
   - Verify that sum of all posting `amount_cents` equals zero.
4. **Posting Dimensions:**
   - Which dimensions are required? (`property_id`, `rentable_unit_id`, `tenancy_id`, `party_id`).
   - Validate dimension ownership hierarchy (`tenancy` -> `rentable_unit` -> `property`).
5. **Idempotency Strategy:**
   - Ensure the event is dispatched via `Accounting::PostEntryService` with `(user_id, source_type, source_id, event_type)`.
6. **Reversal / Void Mechanics:**
   - Define how the event is cancelled (use `Accounting::ReverseEntryService`).
   - If accompanied by a replacement event, execute reversal and replacement within a single database transaction.
7. **Operational Reporting:**
   - Update `Accounting::ActivityRow` and `Accounting::ActivityProjector` if the event requires human-readable display in property or tenancy statements.
8. **Tax Reporting Semantics:**
   - Add classification in `TaxReporting::ScheduleEEventMap.classify_income_event`.
   - If the event is non-taxable or operational only, map to `:excluded`.
   - If the event requires human classification, map to `:review_required`.
9. **Ingestion Integration:**
   - If the event can be imported from bank/payment documents, update `ImportedTransaction` and confirmation services.

