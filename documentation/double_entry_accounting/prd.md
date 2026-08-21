# PRD: Rental Domain and Double-Entry Accounting Architecture

## Status

Proposed.

## Summary

Refactor Yanushi around two cooperating models:

1. A **rental-property domain model** that represents properties, rentable units, tenancies, parties, rent terms, charges, receipts, expenses, and security deposits in the language of property management.
2. A **constrained double-entry accounting ledger** that records the financial effect of those domain events using immutable journal entries and postings.

The rental domain remains the interface through which the application operates. Users record rent, payments, expenses, deposits, and corrections rather than manually constructing debits and credits.

The accounting ledger becomes the authoritative source for financial balances and reporting. Domain financial records are the semantic source events from which ledger entries are posted.

Yanushi must not become a general-purpose bookkeeping product. The accounting engine exists to make rental-property bookkeeping internally consistent, auditable, and extensible.

No production data exists. This work may replace existing tables and models directly without compatibility migrations, data backfills, or preservation of the current database schema.

---

# 1. Motivation

Yanushi currently models its financial state using separate application records such as scheduled rents, tenant payments, tenant charges, and expenses, with queries combining those records to derive balances and the unified financial ledger. The current schema also associates leases directly with properties and tenant charges directly with expenses.

That model is simple but embeds several assumptions that will become increasingly expensive to remove:

- a property is the smallest rentable object;
- a lease is simultaneously an occupancy relationship, financial account, and set of rent terms;
- all tenant charges are reimbursements of expenses;
- all money received from tenants behaves like rent;
- tenant balances can be reconstructed by summing several unrelated tables;
- payer identity is not a durable property of the final payment;
- tax classifications overlap with operational property classifications;
- financial reports derive correctness from application-specific query logic rather than accounting invariants.

The absence of production data makes this the right time to establish more durable domain boundaries.

---

# 2. Goals

This project must:

1. Model multifamily and multi-unit properties without special cases.
2. Separate the durable tenancy relationship from effective-dated rental terms.
3. Support individual and organizational renters and payers.
4. Represent arbitrary tenant charges without requiring an associated landlord expense.
5. Distinguish ordinary tenant receipts from refundable security deposits.
6. Preserve payer identity after document ingestion.
7. Establish a complete double-entry ledger for posted Yanushi financial events.
8. Make tenant balances derivable from ledger postings.
9. Make property financial reporting derivable from ledger postings.
10. Preserve Yanushi's running-account behavior without requiring users to manually match every payment to a rent charge.
11. Make financial corrections auditable through reversals rather than destructive edits.
12. Make posting idempotent so retries and duplicate ingestion cannot duplicate financial effects.
13. Keep tax reporting separate from operational property classification.
14. Preserve the existing principle that document ingestion produces candidates that require confirmation before they affect durable financial state.
15. Keep accounting mechanics behind domain-oriented application services and UI.

---

# 3. Non-goals

This project does not turn Yanushi into QuickBooks or a general accounting package.

The initial architecture does **not** require:

- arbitrary user-authored journal entries;
- a journal-entry editor;
- accounts payable;
- vendor invoices;
- payroll;
- inventory accounting;
- bank reconciliation;
- bank-feed synchronization;
- closing periods;
- fiscal-year locking;
- consolidated legal entities;
- foreign currency;
- exchange-rate accounting;
- arbitrary accounting bases;
- general-purpose invoicing;
- GAAP financial statement certification;
- depreciation schedules or fixed-asset accounting;
- automatic tax advice;
- arbitrary user-configurable charts of accounts.

The architecture must leave room for some of these features without implementing them now.

---

# 4. Architectural principles

## 4.1 Rental concepts remain first-class

Accounting primitives must not replace rental-domain concepts.

Yanushi should expose operations such as:

- create tenancy;
- change rent;
- assess rent;
- record tenant payment;
- charge late fee;
- pass through utility expense;
- record property expense;
- receive security deposit;
- refund security deposit;
- apply security deposit;
- correct payment.

It should not expose those operations as:

- debit account 1010;
- credit account 4010;
- create journal line.

The domain operation determines the accounting treatment.

---

## 4.2 Every posted financial event has one accounting representation

A financial event that affects money, receivables, liabilities, income, or expenses must produce a balanced journal entry.

Application reports must not independently reproduce accounting logic by summing domain tables.

For example, tenant balance must eventually be:

```text
balance of Tenant Receivable postings for the tenancy
```

rather than:

```text
scheduled rents
+ tenant charges
- tenant payments
```

---

## 4.3 Domain records explain why; ledger records explain what happened financially

A `Charge` answers questions such as:

- What was the tenant charged for?
- When was it due?
- Was it rent or a reimbursement?
- Which rent term produced it?
- Which expense produced a reimbursement?

A journal entry answers:

- Which accounts changed?
- By how much?
- When?
- Under which property, unit, tenancy, and party dimensions?
- Has the transaction been reversed?

Neither model replaces the other.

---

## 4.4 Posted financial history is immutable

Once a financial event has been posted:

- its monetary fields must not be edited in place;
- its journal entry must not be edited;
- its postings must not be edited or deleted.

A correction creates:

1. a reversing journal entry;
2. a replacement domain event if appropriate;
3. a replacement journal entry.

The UI may present this as "Edit" or "Correct", but persistence must retain the audit trail.

---

## 4.5 The ledger is balanced by construction

Every journal entry must satisfy:

```text
sum(posting.amount_cents) == 0
```

Yanushi will use the convention:

```text
positive amount = debit
negative amount = credit
```

No posted journal entry may exist in an unbalanced state.

Journal entries and all of their postings must be persisted atomically.

---

# 5. Target domain model

```text
User
│
├── Party
│   └── PartyAlias
│
├── Property
│   ├── RentableUnit
│   │   └── Tenancy
│   │       ├── TenancyParty ── Party
│   │       ├── RentTerm
│   │       ├── Charge
│   │       ├── Receipt ── Party
│   │       └── SecurityDeposit
│   │           └── SecurityDepositTransaction
│   │
│   ├── Expense
│   └── PropertyTaxProfile
│
├── Account
│
├── JournalEntry
│   └── Posting
│
└── SourceDocument
    └── ImportedTransaction
```

---

# 6. Property and rentable units

## 6.1 Property

Replace `RentalProperty` with `Property`.

`Property` represents the owned or managed real-estate asset.

Suggested fields:

```text
id
user_id
address
asset_type
square_footage
created_at
updated_at
```

Suggested `asset_type` values:

```text
single_family
multifamily
commercial
mixed_use
land
other
```

`asset_type` is an operational description of the asset.

It must not include Schedule E-specific classifications such as `royalties` or `self_rental`.

---

## 6.2 RentableUnit

Every tenancy belongs to a `RentableUnit`, never directly to a property.

Suggested fields:

```text
id
property_id
name
unit_identifier
square_footage
active
created_at
updated_at
```

Examples:

```text
Property: 100 Main Street
  Unit: Main House
```

```text
Property: 100 Main Street
  Unit: Apartment 1
  Unit: Apartment 2
  Unit: Apartment 3
```

A property with only one rentable space must still have one unit.

The UI may hide the unit abstraction for single-unit properties.

### Invariants

- Every property has at least one rentable unit before a tenancy can be created.
- A tenancy belongs to exactly one rentable unit.
- Units cannot move between properties after financial activity exists.

---

# 7. Parties

## 7.1 Party

Replace `Tenant` with `Party`.

A party is a person or organization that can participate in a tenancy or financial transaction.

Suggested fields:

```text
id
user_id
party_type
display_name
email_address
phone_number
mailing_address
created_at
updated_at
```

`party_type`:

```text
individual
organization
```

Do not require separate first and last names in this project.

---

## 7.2 PartyAlias

Replace `TenantAlias` with `PartyAlias`.

Aliases remain useful for matching imported documents.

Suggested fields:

```text
id
party_id
alias_name
created_at
updated_at
```

Alias matching must remain case-insensitive.

---

# 8. Tenancy

Replace `Lease` as the financial aggregate with `Tenancy`.

A tenancy represents the durable occupancy and tenant-account relationship for a rentable unit.

Suggested fields:

```text
id
rentable_unit_id
commencement_date
termination_date
agreement_type
late_period_days
created_at
updated_at
```

Suggested `agreement_type`:

```text
fixed_term
month_to_month
other
```

The tenancy does **not** contain a single permanent rent amount.

The tenancy is the scope of the tenant receivable balance.

---

# 9. Tenancy parties

Replace `LeaseTenant` with `TenancyParty`.

Suggested fields:

```text
id
tenancy_id
party_id
role
effective_from
effective_until
created_at
updated_at
```

Suggested roles:

```text
tenant
guarantor
occupant
```

This allows party membership to change over time without destroying historical tenancy membership.

### Invariants

- At least one `tenant` role must exist for an active tenancy.
- Effective ranges for the same party and role must not overlap.
- A guarantor or occupant does not automatically become the payer on a receipt.

---

# 10. Rent terms

Move rental economics out of `Tenancy` into effective-dated `RentTerm` records.

Suggested fields:

```text
id
tenancy_id
amount_cents
frequency
due_day
effective_from
effective_until
created_at
updated_at
```

Initial supported frequency:

```text
monthly
```

The model should use an enum or similarly extensible representation so additional frequencies can be added later.

### Example

```text
2026-01-01 through 2026-06-30
$2,000/month

2026-07-01 onward
$2,150/month
```

Both terms belong to the same tenancy.

### Invariants

- Rent terms for a tenancy must not overlap.
- `amount_cents > 0`.
- `due_day` must be valid for the supported frequency.
- Posted historical rent charges are never modified when a rent term changes.

---

# 11. Charges

Replace both `ScheduledRent` and `TenantCharge` with `Charge`.

A charge represents an amount owed by the tenancy.

Suggested fields:

```text
id
tenancy_id
charge_kind
amount_cents
charge_date
due_on
description

rent_term_id            nullable
source_expense_id       nullable

service_period_start    nullable
service_period_end      nullable

posted_at
voided_at
superseded_by_id        nullable

created_at
updated_at
```

Suggested `charge_kind`:

```text
rent
late_fee
reimbursement
other
```

### Rent charge

A generated monthly rent obligation is:

```text
charge_kind: rent
rent_term_id: ...
service_period_start: ...
service_period_end: ...
```

### Reimbursement charge

A utility or repair reimbursement may be:

```text
charge_kind: reimbursement
source_expense_id: ...
```

`source_expense_id` is optional for the general `Charge` model but required by application validation when `charge_kind == reimbursement` if the reimbursement originated from a Yanushi expense.

### Late fee

A late fee needs no `Expense`.

```text
charge_kind: late_fee
source_expense_id: nil
```

---

# 12. Rent generation

Replace scheduled-rent generation with charge generation.

A rent-generation service must:

1. identify the active `RentTerm` for a tenancy and service period;
2. compute the charge amount;
3. determine its due date;
4. create one `Charge(kind: rent)`;
5. post the charge;
6. behave idempotently.

Use a uniqueness key sufficient to prevent duplicate rent generation, for example:

```text
rent_term_id
service_period_start
```

with an appropriate unique index.

Do not infer whether a month's rent exists by checking amounts or descriptions.

---

# 13. Receipts

Replace `TenantPayment` with `Receipt`.

A receipt represents ordinary money received and applied to the tenancy's running account.

Suggested fields:

```text
id
tenancy_id
payer_party_id
amount_cents
received_on
payment_method
external_reference
memo

posted_at
voided_at
superseded_by_id

created_at
updated_at
```

### Required semantics

`payer_party_id` records who actually made the payment.

The payer does not have to be the only tenant on the tenancy.

A parent, employer, organization, guarantor, or other payer can be represented as a `Party`.

The tenancy owns the receivable balance. The payer identifies the source of the receipt.

---

# 14. Running-account behavior

Yanushi must preserve running-account semantics.

A receipt is **not required to reference an individual rent charge**.

For the MVP:

```text
tenancy balance
= net balance of the Tenant Receivable account
  filtered to that tenancy
```

Payments may therefore create a credit balance.

Example:

```text
Rent charge                +$2,000 owed
Payment                    -$3,000 owed
                           -------
Tenant account credit       $1,000
```

A subsequent $2,000 rent charge results in:

```text
Tenant owes                 $1,000
```

No user-visible matching step is required.

---

# 15. Receipt allocations

Explicit payment-to-charge allocation is **not required for MVP balance calculation**.

Do not make allocation a prerequisite for receiving or posting money.

The schema may reserve the concept for later:

```text
ReceiptAllocation
  receipt_id
  charge_id
  amount_cents
```

but this project should only implement allocations if another required feature cannot be correct without them.

Running-account balance correctness must not depend on allocation rows.

---

# 16. Security deposits

Security deposits must not be represented as ordinary receipts against tenant receivables.

## 16.1 SecurityDeposit

Suggested fields:

```text
id
tenancy_id
required_amount_cents
due_on
created_at
updated_at
```

This record represents the contractual deposit requirement.

The amount held is derived from its transactions, not stored as an independently mutable balance.

---

## 16.2 SecurityDepositTransaction

Suggested fields:

```text
id
security_deposit_id
transaction_kind
amount_cents
occurred_on
party_id
charge_id             nullable
external_reference    nullable

posted_at
voided_at

created_at
updated_at
```

Suggested kinds:

```text
received
refunded
applied
```

### Received

Money is received but remains a liability.

### Refunded

Money is returned and reduces the liability.

### Applied

Deposit liability is used to settle an existing tenant charge.

For an application:

```text
charge_id is required
```

The charge remains the semantic reason the tenant owed money.

The security-deposit application merely changes how the obligation was settled.

### Invariants

- A security deposit must never become a normal `Receipt`.
- Deposit transactions cannot reduce the held liability below zero.
- An application cannot exceed the outstanding deposit liability.
- An application cannot exceed the relevant tenant-account amount being settled unless explicitly supported later.

---

# 17. Expenses

Retain `Expense` as a rental-domain concept, but redesign it around the new model.

Suggested fields:

```text
id
property_id
rentable_unit_id       nullable
expense_kind
amount_cents
paid_on
description
vendor_name            nullable
external_reference     nullable

posted_at
voided_at
superseded_by_id

created_at
updated_at
```

An expense belongs to a property.

It may optionally belong to a specific rentable unit.

Suggested bookkeeping categories should cover the categories Yanushi needs operationally, for example:

```text
advertising
cleaning_and_maintenance
insurance
legal_and_professional
management
repairs
supplies
taxes
utilities
other
```

The exact list may preserve useful existing categories where appropriate.

Tax reporting must map these bookkeeping categories/accounts into tax-report categories rather than treating the expense model itself as a tax form.

---

# 18. Expense reimbursement

A reimbursable expense and a tenant receivable are two distinct events.

Example:

```text
Utility Expense
  amount: $300
  property: 100 Main Street

Charge
  kind: reimbursement
  amount: $300
  tenancy: Apartment 2 tenancy
  source_expense: Utility Expense
```

The expense exists even if it is never reimbursed.

The charge exists even if the tenant never pays it.

One expense may eventually produce more than one reimbursement charge.

Do not model this relationship as `Expense has_one TenantCharge`.

---

# 19. Accounting model

## 19.1 Account

Create `Account`.

Accounts belong to the Yanushi user, not individual properties.

This allows one cash account or chart of accounts to span multiple properties while property-level reporting uses posting dimensions.

Suggested fields:

```text
id
user_id
key
name
account_type
active
created_at
updated_at
```

Suggested account types:

```text
asset
liability
equity
income
expense
```

### Stable account keys

`key` is an application-level identifier and must be unique per user.

Examples:

```text
cash
tenant_receivable
security_deposits_held
rental_income
late_fee_income
reimbursement_income

expense_advertising
expense_cleaning_maintenance
expense_insurance
expense_legal_professional
expense_management
expense_repairs
expense_supplies
expense_taxes
expense_utilities
expense_other

opening_balance_equity
```

Application posting rules should reference stable keys rather than account database IDs.

### Account mutability

Once referenced by a posting:

- account type cannot change;
- account key cannot change;
- account cannot be deleted.

Display name may change.

Unused accounts may be archived.

---

# 20. Chart of accounts provisioning

Every user receives a system-defined chart of accounts.

Provisioning must be idempotent.

Creating a user or initializing accounting for an existing development user must create any missing system accounts without duplicating existing accounts.

Do not add a general-purpose account-management UI in this project.

---

# 21. JournalEntry

Create `JournalEntry`.

Suggested fields:

```text
id
user_id

source_type
source_id
event_type

occurred_on
description
posted_at

reversal_of_id       nullable

created_at
```

Do not use an editable `draft` state for persisted journal entries in the initial implementation.

A journal entry is constructed and validated in memory, then persisted as a complete posted transaction.

### Source identity

`source_type` and `source_id` identify the domain event that caused the posting.

Examples:

```text
Charge / 123
Receipt / 456
Expense / 789
SecurityDepositTransaction / 101
```

`event_type` disambiguates the posting event.

Examples:

```text
charge_posted
receipt_posted
expense_posted
deposit_received
deposit_refunded
deposit_applied
reversal
```

Add an appropriate uniqueness constraint preventing the same source event from posting twice.

---

# 22. Posting

Create `Posting`.

Suggested fields:

```text
id
journal_entry_id
account_id
amount_cents

property_id          nullable
rentable_unit_id     nullable
tenancy_id           nullable
party_id             nullable

memo                  nullable
created_at
```

Convention:

```text
amount_cents > 0     debit
amount_cents < 0     credit
```

Posting amounts must never be zero.

### Why dimensions belong on postings

Property, unit, tenancy, and party are reporting dimensions rather than accounts.

Do not create separate accounts such as:

```text
Apartment 1 Rent Income
Apartment 2 Rent Income
Apartment 3 Rent Income
```

Instead:

```text
Account:
  Rental Income

Posting:
  account: Rental Income
  property: 100 Main Street
  unit: Apartment 2
  tenancy: ...
```

This keeps the chart of accounts stable as the portfolio changes.

---

# 23. Accounting invariants

The accounting implementation must enforce all of the following:

### Balanced entries

```text
sum(postings.amount_cents) == 0
```

for every journal entry.

### Minimum lines

Every journal entry has at least two postings.

### Atomic posting

A journal entry and all postings are created within one database transaction.

No code path may leave a partial journal entry.

### Idempotency

Posting the same source event twice produces one accounting event.

Retries must be safe.

### Ownership consistency

All of the following must belong to the same Yanushi user:

- journal entry;
- accounts;
- property;
- unit;
- tenancy;
- party.

### Dimensional consistency

If a posting has:

```text
rentable_unit_id
```

its property must match `property_id`.

If it has:

```text
tenancy_id
```

the tenancy must belong to that unit.

### Immutability

Posted journal entries and postings cannot be updated or destroyed through normal application operations.

---

# 24. Posting service architecture

Accounting entry creation must go through a narrow service boundary.

Suggested namespace:

```text
Accounting::PostingBuilder
Accounting::PostCharge
Accounting::PostReceipt
Accounting::PostExpense
Accounting::PostSecurityDepositTransaction
Accounting::ReverseJournalEntry
```

or equivalent.

Controllers and models must not manually create individual `Posting` rows.

A poster must:

1. identify required accounts;
2. construct all postings;
3. validate dimensions;
4. verify the entry balances;
5. acquire any necessary locks;
6. persist the journal entry and postings atomically;
7. mark the source record as posted;
8. return the existing journal entry if the event was already posted.

Posting services should have precise RBS signatures and be included in Steep checking.

---

# 25. Posting rules

## 25.1 Rent charge

For a $2,000 rent charge:

```text
Dr Tenant Receivable        $2,000
Cr Rental Income            $2,000
```

Dimensions:

```text
property
rentable_unit
tenancy
```

The income line may also carry tenancy context.

---

## 25.2 Late fee

For a $50 late fee:

```text
Dr Tenant Receivable           $50
Cr Late Fee Income             $50
```

---

## 25.3 Expense reimbursement charge

For a $300 utility reimbursement charged to the tenant:

```text
Dr Tenant Receivable          $300
Cr Reimbursement Income       $300
```

The underlying landlord expense is posted separately.

---

## 25.4 Tenant receipt

For a $2,000 payment:

```text
Dr Cash                     $2,000
Cr Tenant Receivable        $2,000
```

Dimensions include:

```text
property
rentable_unit
tenancy
payer party
```

A payment larger than the current tenant receivable is allowed.

The tenant receivable subledger may therefore carry a credit balance.

Do not automatically reclassify that credit into another liability account in the initial implementation.

That behavior can be added later if formal balance-sheet presentation requires it.

---

## 25.5 Property expense

For a $500 repair:

```text
Dr Repairs Expense             $500
Cr Cash                        $500
```

The debit account is selected by the expense category mapping.

---

## 25.6 Security deposit received

For a $2,000 refundable deposit:

```text
Dr Cash                      $2,000
Cr Security Deposits Held    $2,000
```

This event does not affect:

```text
Tenant Receivable
Rental Income
```

---

## 25.7 Security deposit refund

For a $2,000 refund:

```text
Dr Security Deposits Held    $2,000
Cr Cash                      $2,000
```

---

## 25.8 Security deposit applied to a charge

Suppose a tenant has a previously-posted $500 damage reimbursement charge.

Applying $500 of the deposit produces:

```text
Dr Security Deposits Held      $500
Cr Tenant Receivable           $500
```

The charge itself already recorded the tenant obligation and its corresponding income/reimbursement classification.

Do not recognize the income a second time when applying the deposit.

---

# 26. Debit/credit presentation

Internally, postings use signed integer amounts.

The application may expose helper methods:

```ruby
posting.debit?
posting.credit?
posting.debit_amount
posting.credit_amount
```

Do not store nullable `debit_amount` and `credit_amount` columns.

---

# 27. Money representation

Replace monetary decimal columns in new financial models with integer cents.

Use:

```text
bigint amount_cents
```

with application validation requiring appropriate positive values on source records.

The initial system supports USD only.

Do not introduce currency conversion in this project.

If a currency column is added for future compatibility, all postings in one journal entry must use the same currency and only USD may currently be accepted.

---

# 28. Accounting basis and reporting semantics

The ledger records the accounting effect of rental-domain events.

A rent charge creates both:

```text
Tenant Receivable
Rental Income
```

before cash is received.

Therefore:

```text
accrual-style Rental Income account balance
```

is **not automatically identical to cash received for tax reporting**.

This distinction is intentional.

Yanushi must expose separately named metrics such as:

```text
rent charged
cash received
tenant receivable
operating expenses
```

rather than labeling all of them generically as "income".

---

# 29. Tax reporting

Schedule E reporting becomes an explicit reporting projection over posted financial events and account classifications.

It must not blindly define:

```text
Schedule E rents received
= Rental Income account balance
```

because unpaid rent charges may already have credited rental income in the management ledger.

For the initial implementation:

- only posted events are reportable;
- unpaid tenant charges must not be reported as cash received merely because they created receivables;
- ordinary posted tenant receipts may contribute to received-rent reporting according to Yanushi's tax-report mapping policy;
- refundable security-deposit receipts must not be included in ordinary rental receipts;
- property expenses are selected from posted expense events/accounts according to their tax mapping;
- reversed events must cancel the original reporting effect.

Keep the mapping implementation isolated, for example:

```text
TaxReporting::ScheduleEQuery
TaxReporting::ScheduleEAccountMap
```

Do not embed Schedule E line names directly into `Property.asset_type`, `Charge`, or the accounting engine.

---

# 30. Property tax profile

Move tax-specific property classification to `PropertyTaxProfile`.

Suggested fields:

```text
id
property_id
tax_year
schedule_e_property_type
created_at
updated_at
```

This deliberately separates:

```text
Property.asset_type
```

from:

```text
PropertyTaxProfile.schedule_e_property_type
```

A tax classification may therefore vary independently of the physical asset model.

Add a uniqueness constraint:

```text
property_id + tax_year
```

---

# 31. Financial ledger UI

The existing "financial ledger" concept should become a projection of journal entries joined to their source records.

Do not continue assembling financial truth independently from four unrelated tables.

The UI may continue to present domain-friendly row types such as:

```text
Rent charge
Tenant payment
Late fee
Utility reimbursement
Expense
Security deposit received
Security deposit refund
```

The accounting lines do not need to be exposed by default.

An optional expandable detail may show:

```text
Tenant Receivable      +$2,000 debit
Rental Income          -$2,000 credit
```

for debugging and auditability.

---

# 32. Tenant balance

Replace `Leases::BalanceQuery` with a tenancy-account query backed by postings.

Conceptually:

```text
Accounting::TenancyBalanceQuery
```

For one tenancy:

```text
balance owed
= sum(Tenant Receivable postings)
```

Using the signed-posting convention:

```text
positive result = tenant owes landlord
negative result = tenant has credit
zero            = settled
```

If the existing UI uses the opposite sign convention, convert it at the presentation boundary rather than changing the accounting convention.

Support:

```text
balance_as_of(date)
current_balance
```

using `JournalEntry.occurred_on`.

---

# 33. Charge status

`Charge` must not persist mutable statuses such as:

```text
paid
unpaid
overdue
```

as independent financial truth.

These are projections.

Examples:

```text
overdue
= due_on < today
  and tenancy has unresolved debit according to charge-status policy
```

Exact per-charge paid status becomes ambiguous under running-account semantics when receipts are not explicitly allocated.

For MVP, prefer tenancy-level states and clearly-defined presentation rules rather than pretending every payment has a one-to-one rent match.

If the UI needs per-charge settlement status, introduce a deterministic allocation projection or explicit allocations as a separate feature.

---

# 34. Document ingestion architecture

Generalize the current payment ingestion pipeline so ingestion remains outside confirmed accounting state.

## 34.1 SourceDocument

Replace or rename `PaymentDocument` with `SourceDocument`.

Suggested fields:

```text
id
user_id
document_type
attachment
status
error_message
created_at
updated_at
```

---

## 34.2 ImportedTransaction

Replace or generalize `PaymentIngestion` as `ImportedTransaction`.

Suggested fields:

```text
id
user_id
source_document_id

source
transaction_kind

amount_cents
occurred_on
payment_method
external_reference

payer_name
payer_username
raw_text

matched_party_id
matched_tenancy_id

status
error_message

confirmed_source_type
confirmed_source_id

created_at
updated_at
```

Possible `transaction_kind` candidates:

```text
tenant_receipt
security_deposit
unknown
```

The parser may be uncertain.

No journal entry is created until the imported transaction is confirmed.

---

# 35. Ingestion confirmation

Confirming an imported ordinary rent/payment transaction must:

1. require a matched tenancy;
2. require or create/resolve a payer party;
3. create a `Receipt`;
4. preserve the parsed payer identity on the imported transaction;
5. post the receipt;
6. store the confirmed `Receipt` reference;
7. mark the import confirmed;
8. perform all durable changes atomically.

Confirming a refundable deposit must instead create:

```text
SecurityDepositTransaction(kind: received)
```

It must not create a `Receipt`.

---

# 36. Ingestion idempotency

Duplicate detection should use source-specific external identity whenever possible.

Relevant uniqueness may include:

```text
user_id
source
payment_method
external_reference
```

Do not rely on:

```text
amount + date + payer
```

as a hard uniqueness constraint because legitimate repeated payments can have identical values.

Repeated confirmation requests for the same imported transaction must return the already-created confirmed source rather than posting twice.

---

# 37. Corrections and reversals

Financial corrections must use explicit reversal semantics.

## 37.1 Reversal entry

Given:

```text
Original:
Dr Cash                $2,000
Cr Tenant Receivable   $2,000
```

a reversal is:

```text
Dr Tenant Receivable   $2,000
Cr Cash                $2,000
```

The reversal journal entry references:

```text
reversal_of_id
```

The original journal entry remains unchanged.

---

## 37.2 Correcting a source record

Example: payment entered as $2,000 but should have been $2,100.

The correction operation:

1. marks the original `Receipt` voided/superseded;
2. creates a reversing journal entry for $2,000;
3. creates a replacement `Receipt` for $2,100;
4. posts the replacement receipt;
5. links the original and replacement records.

The entire operation is transactional.

The UI may describe this as:

```text
Correct payment
```

rather than exposing accounting terminology.

---

# 38. Deletion policy

Unposted setup records may be deleted when safe.

Posted financial records may not be hard-deleted.

This includes:

- charges;
- receipts;
- expenses;
- security-deposit transactions;
- journal entries;
- postings.

Properties, units, tenancies, parties, and accounts with financial history should be archived or deactivated rather than cascaded away.

Avoid `dependent: :destroy` on associations that can contain posted accounting history.

---

# 39. Database constraints

Use database constraints wherever straightforward.

Required constraints include:

- non-null foreign keys;
- unique account key per user;
- unique PartyAlias as appropriate;
- positive source monetary amounts;
- non-zero posting amounts;
- unique posting identity for each source event;
- unique rent generation key;
- unique property tax profile per property/year;
- referential foreign keys;
- uniqueness for imported external transaction identity where reliable.

Cross-row double-entry balance remains enforced through the accounting posting boundary and test suite unless a PostgreSQL-level deferred constraint is introduced deliberately.

Do not switch from `schema.rb` to `structure.sql` solely for this project unless a database trigger becomes necessary.

---

# 40. Concurrency

Posting must be correct under retries and concurrent requests.

At minimum:

- the unique source-event constraint prevents duplicate journal entries;
- confirmation operates in a database transaction;
- rent generation is protected by a unique generation key;
- correction/reversal operations lock the source event or otherwise prevent two simultaneous corrections;
- security-deposit application protects against concurrent over-application.

Handle unique-constraint races as successful idempotent retries when the existing record represents the same operation.

---

# 41. Query architecture

Introduce accounting/reporting queries rather than placing aggregation logic on Active Record models.

Suggested structure:

```text
app/queries/accounting/tenancy_balance_query.rb
app/queries/accounting/property_ledger_query.rb
app/queries/accounting/property_summary_query.rb
app/queries/accounting/account_activity_query.rb

app/queries/tax_reporting/schedule_e_query.rb
```

Domain models may delegate convenience methods to these queries.

Avoid large financial SQL expressions inside controllers or views.

---

# 42. Application-service boundaries

Suggested commands:

```text
Tenancies::Create
Tenancies::AddParty
RentTerms::Create
RentTerms::ChangeRent

Charges::AssessRent
Charges::CreateFee
Charges::CreateReimbursement
Charges::Void

Receipts::Record
Receipts::Correct
Receipts::Void

Expenses::Record
Expenses::Correct
Expenses::Void

SecurityDeposits::Receive
SecurityDeposits::Refund
SecurityDeposits::Apply

Accounting::PostCharge
Accounting::PostReceipt
Accounting::PostExpense
Accounting::PostSecurityDepositTransaction
Accounting::ReverseJournalEntry
```

Exact class naming may follow existing Yanushi conventions.

The important boundary is that business operations own intent and accounting services own posting mechanics.

---

# 43. UI implications

The architecture should not make the user perform bookkeeping work that Yanushi can infer.

## Tenancy page

Show:

```text
Current balance
Next rent due
Current monthly rent
Parties
Deposit required
Deposit currently held
Recent account activity
```

## Property ledger

Show domain events in chronological order.

Suggested row labels:

```text
Rent
Payment
Late fee
Reimbursement
Expense
Security deposit
Deposit refund
Deposit applied
Correction
```

## Accounting detail

Journal entry details may be hidden behind:

```text
View accounting entry
```

This is primarily an audit/debug feature.

No debit/credit knowledge should be required for normal use.

---

# 44. Migration strategy

There is no production data to preserve.

Prefer a clean schema transition rather than carrying transitional columns and compatibility code.

The implementation may:

- replace old development migrations;
- reset development databases;
- remove obsolete tables immediately once replacement code exists;
- rewrite seeds and fixtures;
- avoid backfill services;
- avoid dual-write code;
- avoid feature flags whose only purpose is migration compatibility.

Do not preserve a flawed model solely to make a nonexistent migration easier.

---

# 45. Models to remove or replace

The completed architecture should remove:

```text
RentalProperty
Lease
LeaseTenant
Tenant
TenantAlias
ScheduledRent
TenantPayment
TenantCharge
```

and replace them with:

```text
Property
RentableUnit
Tenancy
TenancyParty
Party
PartyAlias
RentTerm
Charge
Receipt
SecurityDeposit
SecurityDepositTransaction
```

`Expense` remains but changes ownership and posting behavior.

`PaymentDocument` and `PaymentIngestion` should be generalized to:

```text
SourceDocument
ImportedTransaction
```

unless implementation review identifies a strong reason to retain the narrower names.

---

# 46. Milestone 1: Core rental domain

Implement:

- `Property`;
- `RentableUnit`;
- `Party`;
- `PartyAlias`;
- `Tenancy`;
- `TenancyParty`;
- `RentTerm`.

Update:

- property creation;
- tenancy creation;
- tenant/party management;
- active tenancy queries;
- fixtures;
- factories;
- RBS;
- Steep coverage.

### Done when

- a single-family property transparently has one rentable unit;
- a multifamily property supports multiple simultaneous tenancies in separate units;
- multiple parties can participate in one tenancy;
- party membership can have effective dates;
- rent can change without replacing the tenancy;
- old `Lease`-centric associations are no longer needed by new code.

---

# 47. Milestone 2: Accounting foundation

Implement:

- `Account`;
- chart-of-accounts provisioning;
- `JournalEntry`;
- `Posting`;
- signed posting convention;
- posting builder;
- balancing validation;
- idempotent source-event posting;
- dimensions;
- reversal support;
- immutability protections.

### Done when

Tests demonstrate that:

```text
sum(all postings for every journal entry) == 0
```

and no application code outside the accounting boundary manually creates postings.

---

# 48. Milestone 3: Charges and tenant receivables

Implement:

- `Charge`;
- rent-charge generation;
- fee charges;
- reimbursement charges;
- charge posting;
- ledger-backed tenancy balances.

Replace:

```text
ScheduledRent
TenantCharge
Leases::BalanceQuery
```

### Done when

The following sequence works entirely from ledger postings:

```text
$2,000 rent charge
$500 partial payment
$100 fee
$2,000 payment
```

and produces the correct tenancy balance after every event.

---

# 49. Milestone 4: Receipts

Implement:

- `Receipt`;
- payer identity;
- ordinary payment posting;
- overpayments;
- corrections;
- reversals;
- manual payment UI.

Replace:

```text
TenantPayment
```

### Done when

- joint tenants can share a tenancy balance while preserving which party paid;
- partial payments work;
- prepayments work;
- overpayments produce a tenancy credit;
- correcting a payment preserves the original journal history.

---

# 50. Milestone 5: Expenses and reimbursements

Refactor `Expense`.

Implement:

- property/unit scope;
- expense categories;
- expense posting;
- reimbursement charge creation;
- one expense to many reimbursement charges.

### Done when

A $300 utility bill reimbursed $150 by each of two separate tenancies produces:

```text
one $300 expense
two $150 tenant charges
three balanced journal entries
```

with no duplicated or hidden expense.

---

# 51. Milestone 6: Security deposits

Implement:

- `SecurityDeposit`;
- receipt;
- refund;
- application to tenant charges;
- security-deposit liability reporting.

### Done when

A refundable deposit:

- increases cash;
- increases deposit liability;
- does not reduce tenant receivable;
- does not count as ordinary rent receipt;
- can later be refunded;
- can later be applied to an existing tenant charge;
- never produces an unbalanced entry.

---

# 52. Milestone 7: Ingestion

Generalize ingestion to:

```text
SourceDocument
ImportedTransaction
```

Update matching to target:

```text
Party
Tenancy
```

rather than tenant/lease.

Confirmation must create either:

```text
Receipt
```

or:

```text
SecurityDepositTransaction
```

depending on confirmed transaction kind.

### Done when

- payer identity survives confirmation;
- re-confirming the same import cannot duplicate money;
- security deposits cannot accidentally become rent receipts;
- no unconfirmed import affects the ledger.

---

# 53. Milestone 8: Ledger and reporting

Replace the existing unified financial ledger query with a ledger-backed projection.

Implement:

- property activity;
- tenancy activity;
- property totals;
- account activity;
- security deposit balance;
- current tenant receivable;
- date-filtered reporting.

### Done when

No primary financial balance is calculated by independently summing the legacy financial tables.

---

# 54. Milestone 9: Tax model

Implement:

- `PropertyTaxProfile`;
- separation of physical asset type and Schedule E classification;
- explicit Schedule E mapping/query;
- cash-received semantics distinct from rent charged;
- exclusion of refundable security deposits;
- reversal handling.

### Done when

Tests prove at minimum:

```text
Unpaid rent charge:
  affects receivable
  does not appear as cash received

Ordinary tenant receipt:
  affects cash-received reporting

Refundable deposit receipt:
  does not appear as ordinary rental receipt

Reversed expense:
  has zero net reporting effect
```

---

# 55. Milestone 10: Cleanup

Delete obsolete:

- models;
- tables;
- queries;
- services;
- views;
- specs;
- signatures;
- documentation.

Update README terminology.

Regenerate Rails RBS after final schema changes.

Run:

```text
bundle exec rbs validate
bundle exec steep check
bundle exec rspec
```

and all existing project quality checks.

---

# 56. Required accounting tests

The test suite must include explicit scenarios for:

## Basic balance

```text
Rent charge       $2,000
Payment           $2,000
Balance                $0
```

## Partial payment

```text
Rent charge       $2,000
Payment             $750
Balance owed       $1,250
```

## Overpayment

```text
Rent charge       $2,000
Payment           $2,500
Credit              $500
```

## Prepayment

```text
Payment           $2,000
Balance credit    $2,000

Later rent        $2,000
Balance                $0
```

## Multiple charge kinds

```text
Rent              $2,000
Late fee             $50
Payment           $2,025
Balance owed          $25
```

## Rent increase

```text
Jan-Jun term      $2,000
Jul onward        $2,100
```

Generated charges must use the correct effective term.

## Joint tenancy

Two parties share one tenancy.

A payment from either party reduces the same tenancy receivable while preserving payer identity.

## Multifamily isolation

Payments and charges for Unit A must not affect Unit B's tenancy balance.

## Security deposit

```text
Receive deposit   $2,000
```

Tenant receivable remains unchanged.

## Deposit refund

Receive $2,000 and refund $2,000.

Deposit liability returns to zero.

## Deposit application

```text
Damage charge       $500
Apply deposit       $500
```

Tenant receivable decreases by $500 and deposit liability decreases by $500.

## Expense reimbursement

```text
Expense              $300
Charge tenant         $300
Tenant pays           $300
```

All three events remain independently visible and balanced.

## Correction

Incorrect $2,000 payment corrected to $2,100.

History contains:

- original entry;
- reversal;
- replacement entry.

Net cash and receivable movement equals $2,100.

## Duplicate confirmation

Submitting the same imported transaction twice creates exactly one source financial event and one posting event.

## Global balancing

For every journal entry fixture and generated scenario:

```text
sum(postings.amount_cents) == 0
```

---

# 57. Required property-based or invariant tests

Where practical, add tests that generate sequences of:

```text
charges
receipts
fees
deposit transactions
expenses
reversals
```

and verify:

1. every journal entry balances;
2. no reversal mutates its original entry;
3. replaying an idempotent command does not change balances;
4. the tenancy balance equals the sum of its tenant-receivable postings;
5. the deposit balance equals the liability postings associated with that tenancy;
6. portfolio posting totals remain balanced.

These tests are more valuable than testing each query implementation independently.

---

# 58. Performance expectations

The initial expected portfolio size is small enough that correctness takes priority over premature aggregation tables.

Queries should nevertheless use indexed dimensions:

```text
journal_entry_id
account_id
property_id
rentable_unit_id
tenancy_id
party_id
occurred_on
```

Add composite indexes based on actual query shapes.

Do not introduce cached financial balances in the first implementation.

Balances should be derived from postings.

If profiling later shows aggregation to be expensive, introduce projections or cached summaries whose correctness can be verified against the ledger.

---

# 59. Authorization

Every domain and accounting record is ultimately owned by a `User`.

Queries must never rely only on opaque record IDs supplied by the client.

Posting services must verify that all referenced objects belong to the same user.

Cross-user journal entries must be impossible even if foreign-key IDs are manually supplied.

---

# 60. Observability

Posting failures should include enough structured context to diagnose:

```text
source type
source ID
event type
expected account keys
balance delta
user ID
```

Never log sensitive document contents unnecessarily.

A balance-validation failure is a programming error and should fail loudly rather than persist an incomplete transaction.

---

# 61. Documentation

Add architecture documentation covering:

1. rental-domain boundaries;
2. accounting sign convention;
3. chart of accounts;
4. posting rules;
5. source-event idempotency;
6. corrections and reversals;
7. running-account semantics;
8. security-deposit semantics;
9. accounting versus tax-reporting basis;
10. how to add a new financial event safely.

The "how to add a financial event" documentation should require developers to answer:

```text
What is the domain source record?
Which accounts does it affect?
Which dimensions belong on its postings?
What is its idempotency key?
How is it reversed?
How does it affect tax reporting, if at all?
```

before adding the event.

---

# 62. Explicit design decisions

The following are decisions for this PRD rather than unresolved implementation questions.

### Decision: full double-entry ledger

Yes.

Every posted financial event represented by this project produces balanced postings.

### Decision: rental domain above accounting domain

Yes.

The application's business API remains rental-oriented.

### Decision: accounts are user-scoped

Yes.

Properties and tenancies are posting dimensions.

### Decision: postings use signed integer cents

Yes.

Positive means debit. Negative means credit.

### Decision: tenant balance is a receivable subledger

Yes.

The tenancy balance is derived from the Tenant Receivable account.

### Decision: overpayment may produce a credit balance in Tenant Receivable

Yes, for the initial implementation.

Do not introduce an unapplied-cash liability solely to avoid negative receivable balances.

### Decision: explicit receipt allocations

Not required for MVP.

Do not restore mandatory payment-to-rent matching.

### Decision: security deposits use a liability account

Yes.

They do not use Tenant Receivable or Rental Income when received.

### Decision: posted history is immutable

Yes.

Corrections use reversals.

### Decision: tax reporting is a separate projection

Yes.

Do not equate GL income account balances automatically with Schedule E cash receipts.

### Decision: one unit even for single-unit property

Yes.

Avoid a property-or-unit polymorphic tenancy relationship.

### Decision: replace Tenant with Party

Yes.

Support people and organizations from the beginning.

### Decision: effective-dated rent terms

Yes.

Do not store one permanent rental amount on the tenancy.

### Decision: clean schema break

Yes.

No migration/backfill compatibility work is required while there is no production data.

---

# 63. Final acceptance criteria

This architecture is complete when all of the following are true:

- [ ] Every tenancy belongs to a rentable unit.
- [ ] Every property can contain one or more rentable units.
- [ ] Parties replace tenants as the reusable person/organization concept.
- [ ] Tenancy membership has roles and effective dates.
- [ ] Rent terms are effective-dated.
- [ ] Scheduled rents are replaced by generated rent charges.
- [ ] Arbitrary tenant charges no longer require expenses.
- [ ] Receipts preserve actual payer identity.
- [ ] Security deposits are represented separately from ordinary receipts.
- [ ] Expenses can exist independently of reimbursements.
- [ ] One expense can support multiple reimbursement charges.
- [ ] Every posted financial event creates a balanced journal entry.
- [ ] Journal entries and postings are immutable.
- [ ] Corrections use reversals.
- [ ] Posting commands are idempotent.
- [ ] Tenant balance comes from Tenant Receivable postings.
- [ ] Property financial reporting comes from ledger postings.
- [ ] Running-account semantics do not require payment-to-charge matching.
- [ ] Overpayments and prepayments behave correctly.
- [ ] Joint tenants share a tenancy account while payer identity remains intact.
- [ ] Multifamily units maintain independent tenancy balances.
- [ ] Refundable deposits do not affect rent receivable or ordinary rent-receipt reporting.
- [ ] Tax classification is separate from physical property classification.
- [ ] Schedule E reporting does not treat unpaid rent as received cash.
- [ ] Document ingestion cannot affect accounting until confirmation.
- [ ] Confirming an imported transaction twice cannot duplicate financial effects.
- [ ] All obsolete lease/payment/charge models and queries are removed.
- [ ] RBS signatures cover new application services and queries.
- [ ] `bundle exec rbs validate` passes.
- [ ] `bundle exec steep check` passes.
- [ ] The complete RSpec suite passes.
- [ ] Documentation explains the accounting invariants and posting rules.

---

# 64. Desired end state

Yanushi should be able to answer each of these questions from one coherent model:

```text
Who rents this unit?

What rent terms were in effect on this date?

How much does this tenancy currently owe?

Who actually made this payment?

How much refundable deposit is currently held?

Why does the tenant owe this charge?

Which landlord expense produced this reimbursement?

How much cash was received for this property?

What expenses were incurred for this property?

Why is this financial balance what it is?

What changed when a transaction was corrected?

Which source document produced this transaction?

Which accounting entries did that transaction create?

Which amounts belong in the selected tax-year report?
```

The rental domain should answer the semantic questions.

The accounting ledger should answer the monetary questions.

The reporting layer should answer the presentation and tax questions.

No one of those layers should be forced to impersonate the others.