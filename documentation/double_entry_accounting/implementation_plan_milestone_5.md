# Implementation Plan: Milestone 5 — Expenses and Reimbursements

## 1. Objective

Turn `Expense` into an immutable posted financial source event.

After this milestone:

```text
Expense
├── property
├── rentable_unit optional
├── expense_kind
├── amount_cents
├── paid_on
├── vendor_name
├── external_reference
├── description
└── lifecycle
      │
      ▼
JournalEntry
├── Dr mapped Expense account
└── Cr Cash
```

A reimbursement remains a separate event:

```text
Expense
    │
    ├── Charge(reimbursement) -> Tenancy A
    └── Charge(reimbursement) -> Tenancy B
```

so:

```text
$300 utility Expense
    Dr Utilities Expense     300
    Cr Cash                  300

$150 reimbursement Charge A
    Dr Tenant Receivable     150
    Cr Reimbursement Income  150

$150 reimbursement Charge B
    Dr Tenant Receivable     150
    Cr Reimbursement Income  150
```

produces exactly:

```text
1 Expense
2 Charges
3 JournalEntries
6 Postings
```

The PRD explicitly requires the underlying landlord Expense and the reimbursement receivable to be separate accounting events. 

---

# 2. Milestone boundary

Implement:

- redesigned `Expense`;
- integer-cent money;
- optional RentableUnit scope;
- operational expense categories;
- category-to-account mapping;
- Expense posting;
- Expense voiding;
- Expense correction/replacement;
- immutable posted Expense history;
- updated reimbursement logic;
- one Expense to many reimbursement Charges;
- Expense UI;
- Expense journal lifecycle;
- interim financial/reporting compatibility.

Do **not** implement:

- accounts payable;
- unpaid vendor bills;
- vendor balances;
- credit-card liability accounts;
- bank reconciliation;
- bank-feed imports;
- depreciation schedules;
- fixed assets;
- vendor refunds;
- arbitrary journal entries;
- general account selection;
- final Schedule E projection;
- expense-document ingestion.

An Expense in Milestone 5 means:

```text
a rental-property cost that has already been paid
```

Therefore its standard posting is:

```text
Dr Expense
Cr Cash
```

The PRD defines that exact treatment and explicitly leaves accounts payable outside the project scope. 

---

# 3. Establish the baseline

Before changing code:

```bash
git status --short

bundle exec rspec
bundle exec rbs validate
bundle exec steep check
bin/rubocop
bin/brakeman --no-pager
```

Inventory the current Expense implementation:

```bash
rg -n \
  'Expense|expenses|expense_date|category|tenant_reimbursable|reimburse_amount|reimburse_tenancy_id' \
  app config db spec sig documentation
```

Also inventory direct persistence:

```bash
rg -n \
  'Expense\.(new|create|create!)|expenses\.(build|create|create!)|\.save!?' \
  app db
```

Every financially-real Expense creation path must eventually go through the new domain service.

---

# 4. Replace the Expense schema

Target:

```text
expenses

id
property_id             NOT NULL
rentable_unit_id        NULL

expense_kind            NOT NULL
amount_cents            BIGINT NOT NULL
paid_on                 DATE NOT NULL

description
vendor_name
external_reference

posted_at
voided_at
superseded_by_id

created_at
updated_at
```

Replace the current decimal `amount`, `category`, and `expense_date` fields. The current table still uses those legacy columns. 

Because there is still no production data to preserve, make this a clean schema cutover rather than maintaining dual columns or backfills.

---

# 5. Database constraints

Add:

```text
amount_cents > 0
```

Add a check constraint restricting `expense_kind` to the supported operational kinds.

Add foreign keys:

```text
property_id       -> properties
rentable_unit_id  -> rentable_units
superseded_by_id  -> expenses
```

Add indexes:

```text
property_id
rentable_unit_id
expense_kind
paid_on
voided_at
superseded_by_id
```

Add:

```text
UNIQUE(superseded_by_id)
WHERE superseded_by_id IS NOT NULL
```

so one replacement cannot supersede multiple original Expenses.

Do not make `external_reference` globally unique. Vendor transaction/reference identifiers are not guaranteed to be globally unique.

---

# 6. Expense kinds

Use operational bookkeeping categories rather than Schedule E line names.

I would use:

```text
advertising
auto_and_travel
cleaning_and_maintenance
commissions
insurance
legal_and_professional
management
mortgage_interest
other_interest
repairs
supplies
taxes
utilities
other
```

This preserves the useful current categories while normalizing a couple of names. The existing model currently includes those categories plus `depreciation_expense`. 

---

# 7. Remove `depreciation_expense` from ordinary Expense

Do **not** retain:

```text
depreciation_expense
```

as a normal Milestone 5 Expense kind.

The Milestone 5 posting rule is:

```text
Dr Expense
Cr Cash
```

but depreciation is non-cash.

Mapping:

```text
Dr Depreciation Expense
Cr Cash
```

would falsely record money leaving the account.

The PRD explicitly excludes depreciation schedules/fixed-asset accounting from this project. 

If depreciation is needed later, model it as a separate non-cash accounting/tax event rather than pretending it was a paid Expense.

---

# 8. Expand the chart of accounts

The current chart already contains the core PRD expense accounts but does not have dedicated accounts for several existing useful categories such as auto/travel, commissions, mortgage interest, and other interest. 

Add:

```text
expense_auto_travel
expense_commissions
expense_mortgage_interest
expense_other_interest
```

Keep:

```text
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
```

All are:

```text
account_type: expense
```

Update `ChartOfAccounts` provisioning tests.

`ensure_for(user)` must remain idempotent and create any newly-added missing system account.

---

# 9. Define one authoritative category map

Do not scatter account selection through models/controllers.

Create something like:

```ruby
Expenses::AccountMap
```

with a fixed mapping:

```text
advertising
    -> expense_advertising

auto_and_travel
    -> expense_auto_travel

cleaning_and_maintenance
    -> expense_cleaning_maintenance

commissions
    -> expense_commissions

insurance
    -> expense_insurance

legal_and_professional
    -> expense_legal_professional

management
    -> expense_management

mortgage_interest
    -> expense_mortgage_interest

other_interest
    -> expense_other_interest

repairs
    -> expense_repairs

supplies
    -> expense_supplies

taxes
    -> expense_taxes

utilities
    -> expense_utilities

other
    -> expense_other
```

This is operational accounting classification.

Do not put Schedule E line numbers or tax-form terminology here. The PRD explicitly separates bookkeeping categories from later tax-report mappings. 

---

# 10. Implement the new `Expense` model

Associations:

```ruby
belongs_to :property
belongs_to :rentable_unit, optional: true

belongs_to :superseded_by,
  class_name: "Expense",
  optional: true

has_one :superseded_expense,
  class_name: "Expense",
  foreign_key: :superseded_by_id

has_many :journal_entries,
  as: :source,
  dependent: :restrict_with_error

has_many :reimbursement_charges,
  -> { where(charge_kind: "reimbursement") },
  class_name: "Charge",
  foreign_key: :source_expense_id,
  dependent: :restrict_with_error
```

Keep the existing one-to-many reimbursement relationship. That part of the current model already matches the target architecture. 

---

# 11. Ownership

Implement:

```ruby
def accounting_user
  property&.user
end
```

Validate:

```text
rentable_unit.property_id == property_id
```

when a unit is supplied.

Do not rely only on controllers for this.

---

# 12. Unit semantics

An Expense may be:

```text
property-wide
```

or:

```text
specific to one RentableUnit
```

Examples:

```text
Property-wide insurance premium
  property = 100 Main
  unit = nil
```

```text
Repair to Apartment 2 sink
  property = 100 Main
  unit = Apartment 2
```

Do not require a unit.

Do not attach ordinary Expenses directly to a Tenancy.

---

# 13. Unit/reimbursement consistency

If:

```text
expense.rentable_unit_id != nil
```

then any new reimbursement Charge must target a Tenancy belonging to that same unit.

So:

```text
Unit A repair
    -> Unit A tenancy reimbursement     allowed

Unit A repair
    -> Unit B tenancy reimbursement     rejected
```

For a property-wide Expense:

```text
rentable_unit_id = nil
```

any Tenancy belonging to the same Property may receive a reimbursement Charge.

This extends the existing same-property reimbursement invariant into the new unit-scoped model.

---

# 14. Money representation

Persist only:

```text
amount_cents
```

Use integer cents throughout domain/accounting calculations.

Provide convenience presentation methods if useful:

```ruby
expense.amount
expense.amount = ...
```

but do not persist decimal dollars.

The PRD requires new financial models to use bigint cents. 

---

# 15. Exact money parsing

Use the same semantics already established for Receipts:

```text
"100"      -> 10000
"100.5"    -> 10050
"100.50"   -> 10050
"100.005"  -> invalid
"abc"      -> invalid
0          -> invalid
negative   -> invalid
```

Do not silently round meaningful fractional cents.

If this logic is now duplicated in three financial domains, this is a reasonable point to extract a small shared:

```text
Money::ParseCents
```

value/service object.

But do not make that extraction a prerequisite if it increases the change surface excessively.

---

# 16. Expense validations

Require:

```text
property
expense_kind
amount_cents > 0
paid_on
```

Validate optional:

```text
vendor_name length
external_reference length
description length
```

Normalize blank optional strings to nil where useful.

Validate `rentable_unit` belongs to `property`.

---

# 17. Expense posting semantics

Create:

```text
Expenses::PostService
```

For a `$500` repair:

```text
Dr Repairs Expense      +50000
Cr Cash                 -50000
```

This is the posting rule specified by the PRD. 

---

# 18. Posting dimensions

For a property-wide Expense, both postings carry:

```text
property
```

and:

```text
rentable_unit = nil
tenancy = nil
party = nil
```

For a unit Expense, both postings carry:

```text
property
rentable_unit
```

and:

```text
tenancy = nil
party = nil
```

`PostingBuilder` already supports property/unit dimensional validation and derives Property from RentableUnit while rejecting contradictory dimensions. 

---

# 19. Expense posting service

Conceptually:

```ruby
account_key =
  Expenses::AccountMap.fetch(expense.expense_kind)

postings = [
  Accounting::PostingSpec.new(
    account_key: account_key,
    amount_cents: expense.amount_cents,
    property: expense.property,
    rentable_unit: expense.rentable_unit
  ),
  Accounting::PostingSpec.new(
    account_key: "cash",
    amount_cents: -expense.amount_cents,
    property: expense.property,
    rentable_unit: expense.rentable_unit
  )
]
```

Then call:

```text
Accounting::PostEntryService
```

Never create JournalEntries/Postings directly.

---

# 20. Journal identity

Use:

```text
source: Expense
event_type: expense_posted
occurred_on: expense.paid_on
```

Use a deterministic description.

For example:

```text
Repair expense
Utility expense
Insurance expense
```

Vendor or free-form description may appear in the domain/UI without becoming an unstable journal idempotency key.

---

# 21. Implement `Expenses::CreateService`

Replace the current generic `Expenses::SaveService` with:

```text
Expenses::CreateService
```

Suggested API:

```ruby
Expenses::CreateService.call(
  property:,
  rentable_unit: nil,
  expense_kind:,
  amount: nil,
  amount_cents: nil,
  paid_on:,
  description: nil,
  vendor_name: nil,
  external_reference: nil
)
```

The service owns:

```text
ownership
unit/property consistency
money parsing
date parsing
Expense persistence
ledger posting
posted_at transition
```

---

# 22. Creation transaction

Within one transaction:

1. validate/normalize inputs;
2. derive owner from Property;
3. validate RentableUnit belongs to Property;
4. persist Expense;
5. call `Expenses::PostService`;
6. roll back if posting fails;
7. set `posted_at` from JournalEntry;
8. commit.

A normal successfully-created Expense must never exist committed as:

```text
Expense persisted
posted_at nil
JournalEntry absent
```

---

# 23. Remove generic SaveService

Delete:

```text
Expenses::SaveService
```

The current service allows an existing Expense to be mutated and then saved, which is incompatible with posted financial immutability once Expense itself reaches the ledger. 

After Milestone 5:

```text
create   -> CreateService
correct  -> CorrectService
void     -> VoidService
```

There should be no generic "save posted expense" path.

---

# 24. Remove reimbursement virtual attributes from Expense

Remove:

```text
tenant_reimbursable
reimburse_tenancy_id
reimburse_amount
reimburse_lease_id
```

from `Expense`.

The current model still carries those compatibility/convenience virtual attributes. 

They blur two independent domain events.

Instead:

```text
Create Expense
      ↓
Expense detail
      ↓
Add Reimbursement Charge
```

The separate reimbursement workflow already exists, so Milestone 5 should complete that separation rather than preserve embedded pseudo-fields.

---

# 25. Simplify new Expense creation

Remove the "Tenant Reimbursable" section from the new Expense form.

Do not create reimbursement Charges implicitly as a side effect of entering an Expense.

This makes the distinction explicit:

```text
Expense = landlord paid money

Reimbursement Charge = tenant now owes money
```

which is exactly the architecture established by the PRD. 

---

# 26. Keep explicit reimbursement creation

Retain:

```text
ExpenseReimbursementsController
Charges::CreateReimbursementService
```

as the application boundary.

The Expense page should expose:

```text
Add Reimbursement Charge
```

until the active reimbursement total reaches the Expense amount.

---

# 27. Refactor reimbursement calculations to cents

Replace current calculations based on decimal:

```text
expense.amount
```

with:

```text
expense.amount_cents
```

For example:

```ruby
def total_active_reimbursement_cents
  reimbursement_charges.active.sum(:amount_cents)
end

def remaining_reimbursable_cents
  [amount_cents - total_active_reimbursement_cents, 0].max
end
```

The current implementation still converts the decimal Expense amount back into cents dynamically. 

---

# 28. Strengthen CreateReimbursementService

After acquiring the Expense row lock, require:

```text
Expense persisted
Expense posted
Expense active
```

Reject:

```text
unposted Expense
voided Expense
superseded Expense
```

Then compute remaining capacity from:

```text
expense.amount_cents
```

instead of converting decimal dollars. The current service already takes an Expense row lock, which is the right concurrency boundary to preserve. 

---

# 29. Re-check after acquiring the lock

Do not validate only before locking.

Inside:

```ruby
expense.with_lock do
```

re-check:

```text
posted?
active?
property
unit
remaining reimbursable amount
```

This prevents a stale Expense object from being reimbursed concurrently with a correction or void.

---

# 30. Reimbursement aggregate invariant

Continue enforcing:

```text
sum(active reimbursement Charge amounts)
<= Expense.amount_cents
```

under the Expense row lock.

Voided historical reimbursement Charges do not consume capacity.

---

# 31. One-to-many reimbursement acceptance

Explicitly test:

```text
Expense
  amount = 30000
  kind = utilities
  property-wide
```

then:

```text
Charge A
  tenancy = Unit A tenancy
  amount = 15000

Charge B
  tenancy = Unit B tenancy
  amount = 15000
```

Result:

```text
Expense remaining reimbursable = 0
```

A third reimbursement must fail.

This is the central Milestone 5 acceptance case. 

---

# 32. Posted Expense immutability

Once:

```text
posted_at.present?
```

ordinary Active Record updates must not change:

```text
property_id
rentable_unit_id
expense_kind
amount_cents
paid_on
description
vendor_name
external_reference
posted_at
```

Lifecycle fields:

```text
voided_at
superseded_by_id
```

may only change through controlled lifecycle services.

Follow the same model-level pattern already used successfully by `Charge`. 

---

# 33. Prevent hard deletion

A posted Expense may never be hard-deleted.

`before_destroy` should reject when:

```text
posted_at present
OR journal_entries exist
```

The PRD explicitly lists Expenses among financial records that may not be hard-deleted once posted. 

Because application-created Expenses are always posted atomically, ordinary Expense deletion effectively disappears from the UI.

---

# 34. Expense lifecycle helpers

Add:

```ruby
scope :active, -> { where(voided_at: nil) }
scope :voided, -> { where.not(voided_at: nil) }
scope :posted, -> { where.not(posted_at: nil) }

def posted?
def voided?
def active?
def superseded?
```

---

# 35. Implement `Expenses::VoidService`

Void means:

```text
the recorded Expense itself was erroneous
```

It does not mean:

```text
the vendor later refunded the money
```

A later vendor refund is a distinct economic event and is out of scope for Milestone 5.

---

# 36. Do not allow void with active reimbursements

Require:

```text
expense.reimbursement_charges.active.none?
```

before voiding the Expense.

If active reimbursement Charges exist:

```text
reject
```

with guidance to void those Charges first.

Otherwise an active Tenant Receivable would continue to claim it originated from an Expense that the landlord has declared nonexistent.

---

# 37. Serialize void against reimbursement creation

`Expenses::VoidService` must:

1. lock Expense;
2. re-check active reimbursement Charges;
3. reject if any exist;
4. reverse the Expense JournalEntry;
5. mark Expense voided;
6. commit.

`CreateReimbursementService` already locks the same Expense row.

Thus:

```text
void vs reimbursement creation
```

has one coherent winner.

---

# 38. Expense void accounting date

A void is a bookkeeping correction.

Always reverse on:

```text
expense.paid_on
```

not `Date.current`.

Example:

```text
incorrect Expense:
Jan 15

discovered:
Feb 20
```

Void produces:

```text
original Jan 15
reversal Jan 15
```

so January historical accounting is restated.

Audit chronology is still visible through:

```text
posted_at
voided_at
```

This is the same distinction established for Receipt correction.

---

# 39. Expense void accounting

Original:

```text
Dr Utilities Expense  +30000
Cr Cash               -30000
```

Void:

```text
Dr Cash               +30000
Cr Utilities Expense  -30000
```

No Expense row is deleted.

---

# 40. Implement `Expenses::CorrectService`

A posted Expense cannot be edited.

Correction creates:

```text
original Expense
original JournalEntry
reversal
replacement Expense
replacement JournalEntry
```

and links:

```text
original.superseded_by = replacement
```

---

# 41. Block correction with active reimbursements

For Milestone 5, require all reimbursement Charges to be voided before correcting the source Expense.

This is intentionally conservative.

Otherwise immutable active Charges would remain attached to a source Expense that has been superseded, while the replacement Expense would appear to have zero reimbursements and could itself be reimbursed again.

The safe workflow is:

```text
1. void affected reimbursement Charges
2. correct Expense
3. create replacement reimbursement Charges as appropriate
```

This keeps the aggregate invariant obvious and auditable.

---

# 42. Correction transaction

Inside one transaction:

1. lock original Expense;
2. validate owner;
3. reject if active reimbursements exist;
4. if already superseded:
   - compare normalized requested replacement;
   - identical => idempotent success;
   - different => conflict;
5. reverse original Expense entry at original `paid_on`;
6. create/post replacement Expense;
7. mark original `voided_at`;
8. set original `superseded_by_id`;
9. commit.

Any failure rolls the entire operation back.

---

# 43. Correction ownership

Replacement Property must belong to:

```text
original_expense.accounting_user
```

Replacement RentableUnit must belong to that Property.

Correction may legitimately fix:

```text
wrong property
wrong unit
wrong amount
wrong category
wrong date
wrong vendor
wrong external reference
wrong description
```

but it may never move an Expense to another user's portfolio.

Enforce this inside `CorrectService`, not only in the controller.

---

# 44. Correction idempotency

Normalize all correction inputs before comparison:

```text
property
rentable_unit
expense_kind
amount_cents
paid_on
description
vendor_name
external_reference
```

An identical repeated correction returns the existing replacement.

A different correction against an already-superseded original returns:

```text
:idempotency_conflict
```

---

# 45. Correction concurrency

Lock the original Expense.

Test:

```text
correction A
vs
correction B
```

Result:

```text
one replacement only
```

Equivalent loser:

```text
returns winner
```

Different loser:

```text
conflict
```

---

# 46. Void vs correction concurrency

Both services lock the same original Expense.

Concurrent:

```text
VoidService
CorrectService
```

must result in exactly one terminal lifecycle:

```text
voided with no replacement
```

or:

```text
superseded by one replacement
```

Never both independent outcomes.

---

# 47. Use the accounting reversal primitive

Both lifecycle services should use:

```text
Accounting::ReverseEntryService
```

rather than manually constructing negative postings.

That service already guarantees exact posting negation and one reversal per original JournalEntry. 

---

# 48. Expense routes

Replace ordinary mutable CRUD with:

```ruby
resources :properties do
  resources :expenses, only: %i[new create]
end

resources :expenses, only: %i[index show new create] do
  resources :reimbursements,
    only: %i[new create],
    controller: "expense_reimbursements"

  member do
    get :correction
    post :correct
    post :void
  end
end
```

Remove:

```text
edit
update
destroy
```

for posted Expenses.

The current routes still expose full `resources :expenses`. 

---

# 49. Nested Property route must be authoritative

For:

```text
POST /properties/:property_id/expenses
```

the route Property is the target Property.

Do not let a body:

```text
expense[property_id]
```

override it.

Use:

```ruby
authenticated_user.properties.find(params[:property_id])
```

for the nested route.

Reject route/body mismatch or omit the hidden body field entirely.

Apply the same hardening pattern established during Milestone 4 Receipt work.

---

# 50. Expense form

Fields:

```text
Property
Unit optional
Category
Amount
Paid on
Vendor
External reference
Description
```

Do not expose accounting account selection.

Do not expose debit/credit concepts.

---

# 51. Unit picker behavior

When Property is selected:

```text
Unit dropdown
```

contains units from that Property.

Include:

```text
Entire property / No specific unit
```

as the blank option.

Client-side filtering is convenience only.

Server-side validation remains authoritative.

---

# 52. Expense detail

Show:

```text
Amount
Paid on
Property
Unit or Property-wide
Category
Vendor
External reference
Description
Accounting status
Reimbursement summary
Correction history
```

Retain the current useful list of linked reimbursement Charges, but now base totals on integer cents. The existing Expense form already presents all reimbursement Charges and their active/voided state. 

---

# 53. Expense lifecycle UI

For active Expense:

```text
Correct Expense
Void Expense
Add Reimbursement Charge
```

For a corrected original:

```text
Corrected
Replacement Expense #...
```

For a replacement:

```text
Replaces Expense #...
```

For a voided Expense:

```text
Voided
```

Do not offer Edit or Delete.

---

# 54. Active reimbursement UX

If active reimbursement Charges exist:

```text
Void Expense
Correct Expense
```

should be disabled or explain:

```text
Void the active reimbursement charges before correcting this expense.
```

Still enforce this in services.

Never rely on the disabled button for correctness.

---

# 55. Reimbursement UI after Expense posting

The Add Reimbursement form should display:

```text
Expense amount
Already reimbursed
Remaining reimbursable
Property
Unit scope
```

If unit-specific:

```text
tenancy picker -> only tenancies for that unit
```

If property-wide:

```text
tenancy picker -> tenancies for the property
```

Again, server validation remains load-bearing.

---

# 56. Remove `reimbursement_charge` singular helper

Delete compatibility helpers that imply one reimbursement:

```text
reimbursement_charge
reimburse_lease_id
```

Use:

```text
reimbursement_charges
```

everywhere.

Milestone 5's one-to-many relationship should no longer carry single-charge compatibility vocabulary.

---

# 57. Property associations

Ensure:

```ruby
Property
  has_many :expenses,
    dependent: :restrict_with_error
```

or equivalent non-destructive behavior.

A Property with posted Expenses cannot be destroyed out from under its accounting history.

---

# 58. RentableUnit associations

Add:

```ruby
RentableUnit
  has_many :expenses,
    dependent: :restrict_with_error
```

if the relationship is directly exposed.

A unit with posted Expense history must not cascade-delete the source records.

Postings already provide an accounting-level restriction, but the domain FK should also communicate the relationship.

---

# 59. Expense financial-history protection

Any existing:

```text
financial_history?
```

or deletion/deactivation guard on Property/Unit should consider Expenses as domain financial history as well as accounting Postings.

---

# 60. Update `Charges::CreateReimbursementService`

Move from:

```text
expense.amount -> BigDecimal -> cents
```

to:

```text
expense.amount_cents
```

The current implementation still recalculates cents from the legacy decimal column. 

Also add:

```text
expense.posted?
expense.active?
```

requirements and unit-scope validation.

---

# 61. Do not post reimbursement through Expense service

Maintain:

```text
Expenses::CreateService
  -> Expense JournalEntry
```

and separately:

```text
Charges::CreateReimbursementService
  -> Charge JournalEntry
```

Do not make Expense posting include expected reimbursement income.

The Expense exists whether or not a tenant is ever charged. 

---

# 62. Do not net reimbursement against Expense

For:

```text
Expense  $300
Charge   $150
```

do **not** store:

```text
net Expense = $150
```

The ledger should show:

```text
Expense account          +300
Cash                     -300

Tenant Receivable        +150
Reimbursement Income     -150
```

The gross events remain separately understandable.

---

# 63. Interim `FinancialItemsQuery`

Milestone 8 will replace the unified property timeline with a ledger-backed projection. Until then, adapt the current domain query rather than redesign it. The current implementation directly unions Charges, Receipts, and Expenses. 

Change Expense fields from:

```text
expense_date
amount
```

to:

```text
paid_on
amount
```

where `amount` is the presentation helper over cents.

Decide explicitly how voided/corrected Expense source rows appear.

Recommended:

```text
show them in history with status
do not make them look active
```

---

# 64. Interim active-years query

Replace Expense-year logic based on:

```text
expense_date
```

with:

```text
paid_on
```

A year containing only Expense activity must remain discoverable.

---

# 65. Interim Schedule E query

Do not implement the final tax architecture here.

But the existing query must survive the schema cutover. It currently groups legacy Expense rows by `category` and sums decimal `amount`. 

Temporarily use only:

```text
Expense.posted.active
```

within:

```text
paid_on: year
```

and aggregate:

```text
amount_cents
```

by:

```text
expense_kind
```

Convert cents to dollars only at the presentation/result boundary.

---

# 66. Reversed/corrected Expense reporting

Because interim Schedule E is still a domain projection, it must exclude:

```text
voided originals
superseded originals
```

and include:

```text
active replacement
```

This mirrors the current interim Receipt treatment.

The ledger itself requires no such filter because reversal postings net the accounting effect.

---

# 67. Do not solve final tax mapping now

Do not equate:

```text
expense_kind
```

with a Schedule E line.

Milestone 9 owns:

```text
TaxReporting::ScheduleEQuery
TaxReporting::ScheduleEAccountMap
```

The PRD specifically requires tax reporting to be a separate projection over posted events/accounts. 

---

# 68. Depreciation in interim Schedule E

If the current Schedule E UI has a depreciation line:

```text
do not populate it from ordinary Expense
```

Leave it zero/unavailable until the tax/depreciation architecture exists.

Do not preserve a financially-wrong cash Expense merely to keep that UI line populated.

---

# 69. Seeds

Replace direct/legacy Expense creation with:

```text
Expenses::CreateService
```

Use explicit:

```text
property
unit if relevant
kind
amount
paid_on
vendor
reference
description
```

Create reimbursement Charges separately through:

```text
Charges::CreateReimbursementService
```

Do not manually create Expense JournalEntries in seeds.

---

# 70. Test the core posting map

For every supported `expense_kind`, assert the mapped debit account.

At minimum:

```text
utilities
  Dr expense_utilities
  Cr cash

repairs
  Dr expense_repairs
  Cr cash

insurance
  Dr expense_insurance
  Cr cash

mortgage_interest
  Dr expense_mortgage_interest
  Cr cash

other
  Dr expense_other
  Cr cash
```

Every entry must balance.

---

# 71. Property-wide dimension tests

Create:

```text
$300 Utilities
Property A
unit nil
```

Assert both Postings:

```text
property_id = A
rentable_unit_id = nil
tenancy_id = nil
party_id = nil
```

---

# 72. Unit-scoped dimension tests

Create:

```text
$500 Repair
Property A
Unit 2
```

Assert both Postings:

```text
property_id = A
rentable_unit_id = Unit 2
tenancy_id = nil
party_id = nil
```

Reject a Unit belonging to Property B.

Reject a Unit owned by another user.

---

# 73. Creation atomicity tests

Force Expense validation failure:

```text
Expense count unchanged
JournalEntry count unchanged
Posting count unchanged
```

Force accounting failure:

```text
same invariant
```

Successful creation:

```text
one Expense
one JournalEntry
two Postings
posted_at set
```

---

# 74. Immutability test matrix

For posted Expense, reject direct updates to:

```text
property
unit
kind
amount
paid_on
description
vendor
external reference
posted_at
voided_at
superseded_by
```

Direct destroy must fail.

---

# 75. Void tests

With no active reimbursement Charges:

```text
void succeeds
original Expense remains
original JournalEntry remains
one reversal exists
reversal date == original paid_on
voided_at set
```

Ledger net:

```text
Expense account = 0 effect
Cash = 0 effect
```

Repeated void:

```text
idempotent
```

---

# 76. Void with reimbursement tests

Given:

```text
Expense $300
active reimbursement Charge $150
```

Expense void:

```text
rejected
```

After voiding the Charge:

```text
Expense void succeeds
```

---

# 77. Correction tests

Correct:

```text
Expense A
Utilities
$300
Jan 10
```

to:

```text
Expense B
Repairs
$350
Jan 12
```

Assert:

```text
A remains
A JournalEntry remains
A reversal exists
B exists
B JournalEntry exists
A.superseded_by == B
A.voided_at present
```

Net accounting must equal only the replacement Expense.

---

# 78. Cross-property correction

Allow:

```text
Property A -> Property B
```

only when both Properties belong to the same user and there are no active reimbursement Charges.

Verify original reversal remains dimensioned to Property A.

Replacement posting is dimensioned to Property B.

This is exactly why corrections must reverse and repost rather than mutate dimensions.

---

# 79. Cross-user correction

Reject:

```text
User A Expense
-> User B Property
```

before reversal starts.

Assert:

```text
original remains active
no reversal
no replacement
```

---

# 80. Correction with active reimbursements

Given any active reimbursement Charge:

```text
CorrectService -> rejected
```

Once all are voided:

```text
CorrectService -> permitted
```

---

# 81. Correction retry tests

Identical retry:

```text
same replacement
no second reversal
no second replacement
```

Conflicting retry:

```text
:idempotency_conflict
```

---

# 82. Lifecycle concurrency tests

Exercise using separate DB connections/threads:

```text
correct vs correct
void vs correct
void vs new reimbursement
correct vs new reimbursement
```

Required invariant:

```text
no active reimbursement may be committed against
an Expense that becomes voided/superseded underneath it
```

The shared Expense row lock is the serialization boundary.

---

# 83. Reimbursement accounting acceptance test

Create:

```text
Expense
  utilities
  $300
  property-wide
```

Ledger:

```text
Dr Utilities Expense      300
Cr Cash                   300
```

Then:

```text
Reimbursement A $150
Reimbursement B $150
```

Ledger adds:

```text
Dr Tenant Receivable A    150
Cr Reimbursement Income   150

Dr Tenant Receivable B    150
Cr Reimbursement Income   150
```

Assert:

```text
Expense.count       1
Charge.count        2
JournalEntry.count  3
Posting.count       6
```

This directly pins the PRD's Milestone 5 done condition. 

---

# 84. No hidden expense test

After the above scenario:

```text
property active Expenses total = $300
```

not:

```text
$600
```

and not:

```text
$0
```

The reimbursement Charges must not create duplicate Expense records or reduce the recorded Expense.

---

# 85. Reimbursement cap tests after schema conversion

Test:

```text
Expense $300

Charge A $150
Charge B $150
Charge C $1
```

C fails.

Void B:

```text
remaining capacity = $150
```

Then another `$150` reimbursement succeeds.

All checks happen under the Expense row lock.

---

# 86. Unit-scoped reimbursement tests

Property-wide Expense:

```text
may reimburse Tenancy A and Tenancy B
```

Unit A Expense:

```text
may reimburse Unit A tenancy
cannot reimburse Unit B tenancy
```

Cross-property always rejected.

---

# 87. Controller authorization tests

Test:

```text
cannot create Expense for another user's Property
cannot submit another user's Unit
cannot correct into another user's Property
cannot void another user's Expense
cannot reimburse into another user's Tenancy
```

---

# 88. Nested Property route tests

Test:

```text
POST /properties/A/expenses
body property_id = B
```

does not create an Expense for B.

Test nonexistent/foreign route Property:

```text
404
no Expense
no JournalEntry
```

---

# 89. Request/UI scenarios

## Property-wide utility

1. Record Expense.
2. Leave Unit blank.
3. Save.
4. Expense posts.
5. Property history shows Expense.

## Unit repair

1. Record repair.
2. Select Unit 2.
3. Save.
4. Posting carries Unit 2.

## Two reimbursements

1. Open $300 Expense.
2. Add $150 to Tenancy A.
3. Add $150 to Tenancy B.
4. Remaining reimbursable becomes $0.
5. Third reimbursement action becomes unavailable.

## Correction

1. Open Expense.
2. Correct amount/category.
3. Original remains historical.
4. Replacement becomes active.

## Void

1. Open erroneous Expense with no active reimbursement.
2. Void.
3. Source remains visible as voided.
4. Accounting reverses.

---

# 90. Update factories

Replace legacy:

```text
amount
category
expense_date
```

with:

```text
amount_cents
expense_kind
paid_on
```

Add traits:

```text
:property_wide
:unit_scoped
:posted_expense
:voided_expense
:corrected_expense
```

For tests that require a financially-real Expense, prefer:

```text
Expenses::CreateService
```

Direct factories are fine for isolated model-validation tests.

---

# 91. RBS/Steep

Add/update signatures for:

```text
Expense

Expenses::AccountMap
Expenses::CreateService
Expenses::PostService
Expenses::VoidService
Expenses::CorrectService

ExpensesController
ExpenseReimbursementsController
Charges::CreateReimbursementService
```

Update Property/RentableUnit associations.

Remove:

```text
Expenses::SaveService
tenant_reimbursable
reimburse_tenancy_id
reimburse_amount
reimburse_lease_id
```

Regenerate Rails signatures:

```bash
bin/rails rbs_rails:all

bundle exec rbs validate
bundle exec steep check
```

Keep the broad application coverage restored in Milestone 2.

---

# 92. Documentation

Add:

```text
documentation/double_entry_accounting/implementation_plan_milestone_5.md
```

Document:

```text
Expense means paid property cost
Expense is not accounts payable
Expense is not depreciation
Expense kind -> account mapping
property-wide vs unit-specific Expense
Expense posting
Expense correction/voiding
reimbursement remains separate
one Expense -> many Charges
reimbursement aggregate cap
active reimbursement blocks Expense correction/void
tax mapping remains separate
```

---

# 93. Search for stale legacy Expense fields

Run:

```bash
rg -n \
  'expense_date|tenant_reimbursable|reimburse_tenancy_id|reimburse_lease_id|reimburse_amount|depreciation_expense' \
  app config db spec sig
```

Expected:

```text
no live application references
```

Historical documentation may remain where explicitly describing the old model.

---

# 94. Search for direct Expense persistence

Run:

```bash
rg -n \
  'Expense\.(new|create|create!)|expenses\.(build|create|create!)' \
  app
```

Review every hit.

Production financially-real creation should be owned by:

```text
Expenses::CreateService
Expenses::CorrectService
```

not controllers.

---

# 95. Search for direct accounting persistence

Run:

```bash
rg -n \
  'Posting\.(new|create|create!)|postings\.(build|create|create!)|JournalEntry\.(new|create|create!)' \
  app
```

Expense implementation must preserve the Milestone 2 service boundary.

---

# 96. Clean-database verification

Because there is no production data to preserve:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate
```

Verify `expenses` contains:

```text
amount_cents
expense_kind
paid_on
rentable_unit_id
vendor_name
external_reference
posted_at
voided_at
superseded_by_id
```

and no longer contains:

```text
amount
category
expense_date
```

---

# 97. Manual smoke test

Using a clean database:

1. Create Property.
2. Verify its units.
3. Record a property-wide insurance Expense.
4. Confirm JournalEntry and postings.
5. Record a unit-specific repair.
6. Confirm unit dimension.
7. Record a $300 utility Expense.
8. Add $150 reimbursement to one tenancy.
9. Add $150 reimbursement to another.
10. Confirm no remaining capacity.
11. Verify tenant balances each increase $150.
12. Try to over-reimburse.
13. Confirm rejection.
14. Try to correct Expense while reimbursements remain active.
15. Confirm rejection.
16. Void both reimbursement Charges.
17. Correct Expense.
18. Confirm original/reversal/replacement history.
19. Add replacement reimbursements if appropriate.
20. Void an Expense with no reimbursement.
21. Confirm accounting reverses.
22. Open property financial history.
23. Open interim Schedule E.
24. Confirm corrected/voided Expense is not double-counted.
25. Verify no ordinary Edit/Delete Expense workflow remains.

---

# 98. Final quality gate

Run:

```bash
bin/rubocop

bundle exec rbs validate
bundle exec steep check

bundle exec rspec

bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

Coverage must remain above the repository CI threshold.

---

# 99. Suggested commit boundaries

**Commit 1: Refactor Expense schema/domain**

Include:

```text
amount_cents
expense_kind
paid_on
unit scope
vendor/reference
lifecycle fields
associations
validations
factories
```

**Commit 2: Expand accounting categories and post Expenses**

Include:

```text
new system accounts
Expenses::AccountMap
Expenses::PostService
Expenses::CreateService
atomicity/posting tests
```

**Commit 3: Cut Expense UI to immutable lifecycle**

Include:

```text
controller/routes
new/create/show
remove edit/update/delete
property/unit picker
remove embedded reimbursement virtual fields
```

**Commit 4: Refactor reimbursements**

Include:

```text
amount_cents integration
posted/active requirement
unit scoping
remaining-cap logic
one-to-many UI/tests
```

**Commit 5: Add Expense void/correction**

Include:

```text
VoidService
CorrectService
correction/void UI
idempotency
ownership
concurrency tests
```

**Commit 6: Reporting compatibility**

Include:

```text
FinancialItemsQuery
ActiveYearsQuery
interim Schedule E
seeds
views
```

**Commit 7: Typing/docs/cleanup**

Include:

```text
RBS
Steep
documentation
stale-reference search
full quality gate
```

---

# 100. Milestone acceptance checklist

### Expense domain

- [ ] `Expense` uses `amount_cents`.
- [ ] `Expense` uses `expense_kind`.
- [ ] `Expense` uses `paid_on`.
- [ ] Property is required.
- [ ] RentableUnit is optional.
- [ ] Unit must belong to Property.
- [ ] Vendor is optional.
- [ ] External reference is optional.
- [ ] Ordinary depreciation is not modeled as a cash Expense.
- [ ] Posted Expense fields are immutable.
- [ ] Posted Expenses cannot be hard-deleted.

### Accounting

- [ ] Each Expense kind maps to one system Expense account.
- [ ] Expense posts Dr mapped Expense account.
- [ ] Expense posts Cr Cash.
- [ ] Property-wide Expense carries Property dimension.
- [ ] Unit Expense carries Property + Unit dimensions.
- [ ] Expense creation and posting are atomic.
- [ ] Posting is idempotent per source event.

### Corrections

- [ ] Void uses exact reversal.
- [ ] Void reversal uses original `paid_on`.
- [ ] Correction preserves original Expense.
- [ ] Correction preserves original JournalEntry.
- [ ] Correction creates one reversal.
- [ ] Correction creates one replacement Expense.
- [ ] Replacement gets its own JournalEntry.
- [ ] Cross-user correction is impossible.
- [ ] Repeated identical correction is idempotent.
- [ ] Conflicting retry fails.
- [ ] Void/correct races serialize.

### Reimbursements

- [ ] Expense supports many reimbursement Charges.
- [ ] Reimbursement is a separate financial event.
- [ ] Reimbursement requires posted active Expense.
- [ ] Total active reimbursements cannot exceed Expense.
- [ ] Reimbursement cap is concurrency-safe.
- [ ] Property-wide Expense may reimburse multiple units.
- [ ] Unit Expense may reimburse only a tenancy in that unit.
- [ ] Active reimbursement blocks Expense void.
- [ ] Active reimbursement blocks Expense correction.
- [ ] Voided reimbursement releases capacity.
- [ ] No singular `TenantCharge` compatibility concepts remain.

### PRD acceptance case

For:

```text
$300 utility Expense
$150 reimbursement to Tenancy A
$150 reimbursement to Tenancy B
```

- [ ] one Expense exists;
- [ ] two reimbursement Charges exist;
- [ ] three JournalEntries exist;
- [ ] six Postings exist;
- [ ] all three entries balance;
- [ ] Expense is recorded only once;
- [ ] Cash decreased $300;
- [ ] Utilities Expense increased $300;
- [ ] Tenant Receivable A increased $150;
- [ ] Tenant Receivable B increased $150;
- [ ] Reimbursement Income increased $300 total.

### UI

- [ ] User records Expense without accounting terminology.
- [ ] Unit is optional.
- [ ] Expense detail shows accounting/lifecycle status.
- [ ] Add Reimbursement Charge is separate.
- [ ] All reimbursement Charges are visible.
- [ ] Remaining reimbursable amount is visible.
- [ ] Correct Expense exists.
- [ ] Void Expense exists.
- [ ] Edit/Delete posted Expense does not exist.

### Reporting compatibility

- [ ] Property financial history uses new Expense fields.
- [ ] Active-year query uses `paid_on`.
- [ ] Interim Schedule E uses active posted Expenses.
- [ ] Corrected originals are not double-counted.
- [ ] Voided Expenses are not counted as current expenses.
- [ ] Final tax-account mapping remains deferred.

### Quality

- [ ] RSpec passes.
- [ ] RuboCop passes.
- [ ] RBS validates.
- [ ] Steep passes.
- [ ] Coverage remains above CI threshold.
- [ ] Security scans pass.
- [ ] Concurrency coverage pins reimbursement/lifecycle locking.

## Desired end state

After Milestone 5, the domain/accounting split should be:

```text
Property
├── Expense
│   ├── optional RentableUnit
│   └── reimbursement Charges
│
└── ...
```

with:

```text
Expense
  "The landlord paid $300 for utilities."

Ledger
  Dr Utilities Expense  $300
  Cr Cash               $300
```

and separately:

```text
Charge A
  "Tenancy A owes $150 reimbursement."

Charge B
  "Tenancy B owes $150 reimbursement."

Ledger
  Dr Tenant Receivable A   $150
  Cr Reimbursement Income  $150

  Dr Tenant Receivable B   $150
  Cr Reimbursement Income  $150
```

That is the key Milestone 5 boundary: **the Expense records the landlord's cost exactly once; reimbursement Charges record tenant obligations independently; the ledger records all three financial effects without netting, duplication, or destructive editing.** 
