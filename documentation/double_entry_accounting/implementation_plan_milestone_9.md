# Milestone 9 implementation plan

## 1. Milestone objective

Implement:

```text
Property
└── PropertyTaxProfile(year)
        ↓
TaxReporting::ScheduleEQuery
        ↓
posted JournalEntries / Postings
        ↓
tax-event / account mappings
        ↓
Schedule E worksheet
```

The initial result should answer:

```text
Property tax classification

Line 3  Rents received

Line 5  Advertising
Line 6  Auto and travel
Line 7  Cleaning and maintenance
Line 8  Commissions
Line 9  Insurance
Line 10 Legal and professional fees
Line 11 Management fees
Line 12 Mortgage interest
Line 13 Other interest
Line 14 Repairs
Line 15 Supplies
Line 16 Taxes
Line 17 Utilities
Line 19 Other

Total expenses
Net rental income/loss before unsupported adjustments
```

These correspond to the current Schedule E Part I layout. The latest Schedule E currently published by the IRS is the **2025** form; its Part I still uses line 3 for rents received and lines 5–19 for these expense categories. 

Do **not** implement depreciation calculations, passive-loss rules, personal-use allocation, basis, Form 8582, or tax advice. Those remain outside the accounting PRD's scope. 

I would call this a **Schedule E worksheet**, not a generated tax return.

---

# 2. Add `PropertyTaxProfile`

Migration:

```text
property_tax_profiles

id
property_id                  NOT NULL
tax_year                     integer NOT NULL
schedule_e_property_type     string NOT NULL
other_description            string NULL
created_at
updated_at
```

Database constraints:

```text
UNIQUE(property_id, tax_year)

tax_year > 1900
```

The PRD explicitly wants one tax profile per Property/year and separates this classification from `Property.asset_type`. 

## 3. Do not derive tax type from physical asset type

Current operational types remain:

```text
single_family
multifamily
commercial
mixed_use
land
other
``` 


Schedule E gets its own enum. For the current IRS form, use semantic internal values:

```text
single_family_residence
multi_family_residence
vacation_short_term_rental
commercial
land
self_rental
other
```

and map those to IRS codes 1–5, 7, and 8.

*(Note: `royalties` / IRS Code 6 belongs on Line 4 of Schedule E rather than Line 3 rental income. Because Milestone 9 is scoped to rental real estate and implements Line 3 rental income, royalty properties are intentionally unsupported and omitted from the domain enum.)*

Do not store `"1"`, `"2"`, etc. as the domain enum. Codes/forms can change; semantic values are more durable. 

## 4. Require an `other_description` for type `other`

Model validation:

```text
schedule_e_property_type == other
    -> other_description required

otherwise
    -> other_description blank
```

Do not infer `"mixed use"` from `Property.asset_type`; make the user choose the tax classification explicitly.

---

# 5. Keep profiles year-specific

Do not add one permanent:

```text
property.schedule_e_type
```

A profile belongs to:

```text
Property + tax_year
```

because tax classification is tax-reporting metadata, not a permanent physical property attribute. That's explicitly the reason the PRD introduces `PropertyTaxProfile`. 

A convenience action may later copy the previous year's profile, but don't silently create it.

---

# 6. Profile CRUD

Suggested nested route:

```ruby
resources :properties do
  resources :tax_profiles,
    controller: "property_tax_profiles",
    only: %i[new create edit update]
end
```

Resolve Property through:

```ruby
authenticated_user.properties.find(params[:property_id])
```

Tax profiles aren't financial events and don't post journal entries.

---

# 7. Make the Schedule E query explicitly tax-namespaced

Delete/replace:

```text
Properties::ScheduleESummaryQuery
```

with:

```text
TaxReporting::ScheduleEQuery
```

and introduce:

```text
TaxReporting::ScheduleEAccountMap
TaxReporting::ScheduleEEventMap
```

The PRD specifically suggests this isolation and says not to embed tax line names in the accounting engine or rental-domain models. 

---

# 8. Define a stable Schedule E result object

For example:

```ruby
ScheduleEResult = Data.define(
  :property,
  :tax_year,
  :tax_profile,
  :rents_received_cents,
  :expenses_by_category_cents,
  :total_expenses_cents,
  :net_income_cents,
  :review_items,
  :warnings
)
```

Use integer cents throughout the query.

Formatting dollars belongs in the view.

---

# 9. Do not derive Schedule E income from `Rental Income`

This is the central M9 rule.

A rent Charge currently produces:

```text
Dr Tenant Receivable
Cr Rental Income
```

before anybody pays. The PRD explicitly says the accrual Rental Income balance cannot be treated as Schedule E cash received. 

Therefore this must pass:

```text
Jan 1:
  Rent Charge $2,000

No Receipt

Schedule E line 3:
  $0
```

even though:

```text
Rental Income account = $2,000 credit
Tenant Receivable      = $2,000 debit
```

---

# 10. Define Schedule E line 3 from ordinary Receipt events

For the initial policy:

```text
posted ordinary Receipt
    -> Schedule E line 3
```

Use the **Cash posting belonging to the Receipt's JournalEntry**, not `Receipt.amount_cents`.

Why use the posting?

Because the milestone's architecture says posted financial events and their reversals are the reporting source of truth. 

Conceptually:

```sql
JournalEntry
  source_type = Receipt
  event_type = receipt_posted
  occurred_on in tax year

JOIN postings
  account = cash
  property = target property
```

Natural positive Cash amount contributes to line 3.

The IRS generally says cash-method taxpayers report rental income when actually or constructively received, and Schedule E line 3 reports rental income received from real estate. 

---

# 11. Do not require receipt-to-charge allocation

Yanushi deliberately uses a running account.

Therefore don't try to answer:

```text
$700 of this receipt paid rent
$50 paid a late fee
$250 reimbursed utilities
```

The accounting model does not know that.

For the initial Schedule E policy, ordinary rental-related Receipt cash belongs to Schedule E line 3. The IRS instructions also note that other rental income is reported on line 3 rather than requiring every dollar to correspond to a monthly rent charge. 

That means the current transitional field:

```text
utility_reimbursements
```

should disappear rather than becoming a second amount that risks double-counting. 

---

# 12. Refundable deposit receipt contributes zero rental income

This must be explicit:

```text
SecurityDepositTransaction(received)
    Dr Cash
    Cr Security Deposits Held

Schedule E line 3 effect:
    $0
```

Do not decide tax income merely because Cash increased.

Both the PRD and current IRS guidance distinguish refundable security deposits from rental income. 

This is one of the milestone's required acceptance tests. 

---

# 13. Treat deposit application as an explicit tax-policy boundary

There is a subtle case M9 should not silently guess about:

```text
refundable deposit received
    -> not income

later deposit applied/kept
    -> potentially tax-relevant
```

Current IRS guidance says a refundable security deposit isn't income when received, but an amount later kept because the tenant fails to meet lease terms may become income in that year; treatment can depend on the circumstance. 

Yanushi currently doesn't contain enough tax-specific information to automate every such case safely.

So for M9 I would classify:

```text
deposit_received  -> excluded
deposit_refunded  -> excluded
deposit_applied   -> review_required
```

and surface deposit applications under:

```text
Items requiring tax review
```

rather than silently adding or excluding them.

Do **not** turn tax nuance into hidden accounting behavior.

---

# 14. Reversal handling for ordinary Receipts

The tax projection must include accounting reversals.

Suppose:

```text
Jan 5 Receipt     +$2,000 Cash
Jan 5 reversal    -$2,000 Cash
Jan 5 replacement +$2,100 Cash
```

Schedule E line 3:

```text
$2,100
```

not:

```text
$4,100
```

and not:

```text
$2,000
```

The reversal entry is already a precise sign inversion of the original postings. 

---

# 15. Recognize reversals by accounting lineage

A reversal has:

```text
source_type = JournalEntry
reversal_of_id = original.id
event_type = reversal
```

So `ScheduleEEventMap` should inspect:

```text
reversal.reversal_of.source_type
reversal.reversal_of.event_type
```

and assign the opposite tax effect to whatever the original event contributed.

Do not inspect only:

```text
reversal.source_type
```

because that's always `JournalEntry`.

---

# 16. Let accounting dates determine tax-year placement

Tax projection should use:

```text
JournalEntry.occurred_on
```

for period membership.

For an ordinary Receipt correction, current lifecycle semantics generally restate on the original receipt date, so original/reversal/replacement remain in the proper reporting period.

For a financial event genuinely reversed in another tax year, the later tax projection should reflect the later reversal rather than mutating the prior ledger.

Do not read `voided_at` as the tax date.

---

# 17. Expense reporting comes from mapped expense account postings

Current Expense posting already maps each Expense kind to a specific expense account. 

That gives a clean tax projection:

```text
Posting account_key
    ↓
ScheduleEAccountMap
    ↓
Schedule E expense category
```

Do not sum:

```ruby
property.expenses.active
```

as the current transitional query does. 

---

# 18. Implement `ScheduleEAccountMap`

Suggested mapping:

```ruby
MAPPING = {
  "expense_advertising" =>
    :advertising,

  "expense_auto_travel" =>
    :auto_and_travel,

  "expense_cleaning_maintenance" =>
    :cleaning_and_maintenance,

  "expense_commissions" =>
    :commissions,

  "expense_insurance" =>
    :insurance,

  "expense_legal_professional" =>
    :legal_and_professional,

  "expense_management" =>
    :management,

  "expense_mortgage_interest" =>
    :mortgage_interest,

  "expense_other_interest" =>
    :other_interest,

  "expense_repairs" =>
    :repairs,

  "expense_supplies" =>
    :supplies,

  "expense_taxes" =>
    :taxes,

  "expense_utilities" =>
    :utilities,

  "expense_other" =>
    :other
}
```

This closely matches the current Schedule E lines. 

---

# 19. Use semantic category names, not IRS line numbers internally

Prefer:

```text
:advertising
:mortgage_interest
:utilities
```

over:

```text
:line_5
:line_12
:line_17
```

Then put form-version presentation in one place:

```text
TaxReporting::ScheduleEFormDefinition
```

For 2025:

```text
advertising       -> line 5
auto_and_travel   -> line 6
...
```

This gives the architecture somewhere to adapt if a later form changes numbering or labels.

---

# 20. Version the form definition by tax year

Introduce something lightweight:

```ruby
TaxReporting::ScheduleEFormDefinition.for(year)
```

Initially:

```text
supported years:
  current known form structure
```

Since 2026 forms aren't necessarily published when 2026 activity is being entered, don't make a future-year report impossible simply because the PDF isn't final.

Instead separate:

```text
semantic tax projection
```

from:

```text
official form line presentation
```

The IRS currently publishes 2025 as the latest Schedule E revision. 

---

# 21. Reversed expense nets through postings

Example:

```text
Expense:
  Dr Utilities $300
  Cr Cash      $300

Reversal:
  Cr Utilities $300
  Dr Cash      $300
```

Schedule E utilities:

```text
$0
```

No:

```text
Expense.active?
```

filter is necessary.

This is explicitly a Milestone 9 done-when scenario. 

---

# 22. Expense corrections work automatically

Example:

```text
Original utility expense    $300
Reversal                    -$300
Replacement                  $350
```

Schedule E utilities:

```text
$350
```

because the mapped expense-account postings naturally net.

This is one of the benefits of M8 having already made the ledger authoritative.

---

# 23. Do not report depreciation as zero without qualification

The current Schedule E has a depreciation line, but Yanushi deliberately does **not** implement depreciation/fixed-asset accounting. 

Therefore don't render:

```text
Depreciation     $0.00
```

as though Yanushi knows there was none.

Render something more explicit:

```text
Depreciation
Not tracked by Yanushi
```

and exclude it from a misleading "complete return" claim.

This is another reason to call the output a worksheet.

---

# 24. `other` expense needs detail

Schedule E line 19 is an "Other" category.

For mapped:

```text
expense_other
```

return:

```text
total cents
+
supporting activity rows
```

so the UI can display:

```text
Other
  Locksmith                  $150
  HOA document fee            $75
                             ----
                              $225
```

Use ledger cents for totals; source Expense descriptions may provide explanatory labels.

---

# 25. Query shape

`ScheduleEQuery.call` should take:

```ruby
property:
tax_year:
```

It should resolve:

```text
PropertyTaxProfile
```

then produce:

```text
income event effects
+
mapped expense postings
+
review items
```

Every query must be property-scoped through Posting dimensions and user ownership.

---

# 26. Missing tax profile is not silently guessed

If:

```text
PropertyTaxProfile(property, year)
```

doesn't exist:

```text
ScheduleEQuery
    -> structured :tax_profile_required result
```

The UI should prompt:

```text
Configure 2026 Schedule E classification
```

Do not infer it from `Property.asset_type`.

---

# 27. Make event mapping explicit

Suggested:

```ruby
TaxReporting::ScheduleEEventMap
```

Initial rules:

```text
Receipt / receipt_posted
    -> rents_received

Receipt reversal
    -> inverse rents_received

SecurityDepositTransaction received
    -> excluded

SecurityDepositTransaction refunded
    -> excluded

SecurityDepositTransaction applied
    -> review_required

Charge / charge_posted
    -> no cash-received effect

Charge reversal
    -> no cash-received effect
```

This is much safer than:

```text
all positive Cash postings = rental income
```

which Milestone 8 already demonstrated is too coarse once bookkeeping reversals and deposits exist.

---

# 28. Keep account mapping separate from event mapping

There are two tax mechanisms:

```text
Income:
    event semantics

Expenses:
    account classification
```

That distinction is intentional.

Income cannot simply use `rental_income` because rent may be unpaid.

Expenses can use expense accounts because `Expense.paid_on` already represents the cash/property expense event and each account corresponds to a tax-oriented expense category. 

---

# 29. Add review items rather than silently dropping unknowns

If M9 encounters:

```text
unmapped expense account
deposit application
unrecognized financial source/event
```

don't simply omit it.

Return:

```text
review_items
```

with:

```text
date
amount
event/source
reason
```

Examples:

```text
Deposit applied — tax treatment requires review
Unmapped expense account — no Schedule E category
```

A tax projection should fail visibly rather than under-report silently.

---

# 30. Fail closed on unmapped expense accounts

For system expense accounts, I would actually make this stronger:

```text
every active expense account
must have an explicit ScheduleEAccountMap entry
```

Add a contract test:

```ruby
expense_keys =
  Accounting::ChartOfAccounts::SYSTEM_ACCOUNTS
    .select { |x| x[:account_type] == "expense" }
    .map { |x| x[:key] }

expect(ScheduleEAccountMap.supported_keys)
  .to contain_exactly(*expense_keys)
```

That catches a future new Expense category whose tax projection was forgotten.

---

# 31. Don't map general income accounts automatically

Do **not** assert:

```text
rental_income
late_fee_income
reimbursement_income
other_tenant_income
    -> Schedule E line 3
```

Those are accrual accounts.

Tax receipt timing comes from received events, not income-account credits.

This is the central separation the PRD asks M9 to establish. 

---

# 32. Property tax UI

Add a tax section to the Property page:

```text
Tax Reporting

2026
Schedule E classification:
  Multi-family residence

[View Schedule E Worksheet]
[Edit Tax Profile]
```

Don't mix this into the operational:

```text
asset_type badge
```

which should continue describing the physical asset.

---

# 33. Schedule E worksheet route

Suggested:

```ruby
resources :properties do
  member do
    get :schedule_e
  end
end
```

URL:

```text
/properties/:id/schedule_e?year=2026
```

Resolve Property through the authenticated user.

---

# 34. Worksheet presentation

A useful page:

```text
Schedule E Worksheet — 2026
123 Main Street

Property type:
2 — Multi-family residence

Income
3  Rents received                    $24,000

Expenses
5  Advertising                           $0
6  Auto and travel                      $300
7  Cleaning and maintenance           $1,500
...
17 Utilities                           $2,400
19 Other                                 $225

Tracked expenses total                $8,425

Tracked net rental income            $15,575
```

Then:

```text
Not tracked by Yanushi
- Depreciation
- Personal-use allocation
- Passive-activity limitations
...
```

and:

```text
Items requiring review
...
```

---

# 35. Avoid a false "tax due" metric

Do not calculate:

```text
estimated tax
```

or:

```text
tax owed
```

M9 is reporting/classification, not a tax-return engine.

The PRD explicitly excludes automatic tax advice. 

---

# 36. Add transaction drill-down

Every number should be auditable.

Click:

```text
Rents received $24,000
```

and show contributing ledger effects:

```text
Jan 3 Receipt — Alice       +$2,000
Feb 2 Receipt — Alice       +$2,000
...
```

Likewise:

```text
Utilities $2,400
```

shows mapped expense postings.

This makes the tax projection explainable rather than a black-box aggregate.

---

# 37. Receipt correction audit example

Test:

```text
2026-01-05 Receipt       $2,000
corrected to             $2,100
```

Expected:

```text
Schedule E rents received $2,100
```

Contributing audit rows may show:

```text
+$2,000 original
-$2,000 reversal
+$2,100 replacement
```

---

# 38. Receipt void test

Given:

```text
Receipt erroneously entered $500
Void as bookkeeping correction
```

Expected:

```text
Schedule E effect $0
```

The original and reversal remain auditable.

---

# 39. Unpaid rent test

Required acceptance:

```text
Charge rent $2,000
```

Expected:

```text
Tenant Receivable         +$2,000
Rental Income ledger      +$2,000 accrual

Schedule E rents received     $0
```

This directly pins the PRD's central tax distinction. 

---

# 40. Ordinary receipt test

Then:

```text
Receipt $750
```

Expected:

```text
Schedule E line 3 $750
```

regardless of the remaining A/R balance.

---

# 41. Prepayment test

Given:

```text
Dec 2026 Receipt $2,000
Jan 2027 Rent Charge $2,000
```

Expected initial cash-basis policy:

```text
2026 Schedule E receipts $2,000
2027 receipt contribution    $0
```

For typical cash-basis rental reporting, advance rent is generally included when received. 

This is an important test precisely because Yanushi does not allocate receipts to charges.

---

# 42. Overpayment test

Given:

```text
Rent charge  $2,000
Receipt      $2,500
```

Tax projection:

```text
ordinary rental receipts $2,500
```

Tenant accounting may show:

```text
$500 credit
```

but Schedule E receipt timing remains based on the cash Receipt.

Do not cap tax receipts to the amount charged.

---

# 43. Security deposit receipt test

Given:

```text
Refundable deposit received $2,000
```

Expected:

```text
Cash                         +$2,000
Deposit liability            +$2,000
Schedule E line 3                 $0
```

This is required by the PRD and consistent with current IRS guidance. 

---

# 44. Deposit refund test

Given:

```text
Deposit received $2,000
Deposit refunded $2,000
```

Expected:

```text
Schedule E line 3 $0
Schedule E expenses $0
review items       $0
```

A refundable liability moving in and back out should not masquerade as rental income/expense.

---

# 45. Deposit application test

Given:

```text
Deposit applied $500 to Charge
```

For the initial conservative policy:

```text
Schedule E automatic effect $0

review item:
  "$500 security deposit applied; review tax treatment"
```

This prevents M9 from embedding hidden tax assumptions into the rental accounting engine.

---

# 46. Expense-category acceptance

Create one `$100` Expense in every supported kind.

Expected:

```text
Advertising                100
Auto/travel                100
Cleaning/maintenance       100
...
Utilities                  100
Other                      100
```

and exact total.

This pins `ScheduleEAccountMap` completely.

---

# 47. Reversed expense acceptance

Required PRD scenario:

```text
Utility Expense $300
reverse it
```

Expected:

```text
Utilities $0
```

not:

```text
Utilities $300
```

because the tax query reads mapped ledger postings rather than `.active` source rows. 

---

# 48. Expense correction acceptance

```text
Utility Expense $300
correct -> $350
```

Expected:

```text
Utilities $350
```

with original/reversal/replacement visible in drill-down.

---

# 49. Property isolation

Two properties:

```text
A receipt $2,000
B receipt $1,500

A utility expense $300
B utility expense $200
```

A's worksheet must show only:

```text
Receipts   $2,000
Utilities    $300
```

Use Posting `property_id`, not loose source associations, for the ledger projection.

---

# 50. Tax-year boundaries

Pin:

```text
Dec 31 2025
Jan 1 2026
```

in both receipts and expenses.

Each must land in exactly one tax year based on:

```text
JournalEntry.occurred_on
```

---

# 51. Reversal crossing year boundary

Explicitly test:

```text
Dec 2025 event
Jan 2026 reversal
```

The tax projection must follow the accounting dates that actually exist.

Do not mutate the prior year's source-table result because `voided_at` changed.

If Yanushi later needs amended-return semantics, that's a separate explicit feature.

---

# 52. Profile uniqueness/concurrency

Two concurrent attempts to create:

```text
Property A
tax_year 2026
```

must yield one profile.

Back this with the unique index, not only model validation.

Return structured conflict/validation behavior to the UI.

---

# 53. Tax profile editing

Because a tax profile itself isn't a posted financial event, allow correction of:

```text
schedule_e_property_type
other_description
```

for that year.

No journal entries are affected.

But the resulting report should change immediately because classification is projection metadata.

---

# 54. Do not let profile changes rewrite physical asset type

Test:

```text
Property.asset_type = mixed_use

2026 profile:
  commercial

2027 profile:
  other
```

`Property.asset_type` remains:

```text
mixed_use
```

through both edits.

That's the exact separation M9 is supposed to establish. 

---

# 55. Remove transitional source-based Schedule E logic

After the new query works, delete:

```text
Properties::ScheduleESummaryQuery
```

and remove direct tax-report arithmetic over:

```text
property.receipts
property.expenses
```

The current query is deliberately transitional and should not survive M9. 

---

# 56. Keep tax mapping out of accounting classes

Search:

```bash
rg -n \
  'Schedule E|schedule_e|rents_received|tax_category' \
  app/models/account.rb \
  app/models/posting.rb \
  app/models/journal_entry.rb \
  app/services/accounting
```

Expected:

```text
no Schedule-E-specific behavior
```

except perhaps generic references from a reporting caller.

Accounting should not know tax-form concepts.

---

# 57. Keep tax mapping out of Expense itself

Don't add:

```ruby
Expense#schedule_e_line
```

or:

```text
expense_kind = schedule_e_line_17
```

Expense remains an operational rental-domain event.

`ScheduleEAccountMap` owns the reporting policy.

---

# 58. Explain why Receipt, not Charge, drives received income

Add to:

```text
documentation/double_entry_accounting/
implementation_plan_milestone_9.md
```

the invariant:

```text
Charge
    recognizes accrual rental income
    and creates receivable

Receipt
    represents ordinary cash received

Schedule E initial cash-received projection
    follows Receipt cash effects,
    not Rental Income credits
```

This is probably the most important piece of documentation in the milestone.

---

# 59. Versioned tax-policy documentation

Document which IRS revision the labels/codes were verified against.

For the implementation now:

```text
Verified against:
2025 Schedule E / 2025 Schedule E instructions
```

Do not claim that the 2026 form is identical before it is published.

The IRS currently identifies 2025 as the current Schedule E revision and directs users to its Schedule E page for future developments. 

---

# 60. RBS strategy

Given the earlier RBS discussion, this milestone is actually one where selective typing is useful.

Hand-write/maintain signatures for:

```text
PropertyTaxProfile

TaxReporting::ScheduleEQuery
TaxReporting::ScheduleEResult
TaxReporting::ScheduleEAccountMap
TaxReporting::ScheduleEEventMap
TaxReporting::ScheduleEFormDefinition
```

because these are stable public boundaries.

I would **not** spend much time adding exhaustive types to the tax controllers/views.

Run Steep while building those query interfaces rather than patching signatures only at the end.

---

# 61. Suggested commit sequence

### Commit 1 — Tax profile

```text
PropertyTaxProfile
migration
model
associations
CRUD
validation
```

### Commit 2 — Tax mapping primitives

```text
ScheduleEAccountMap
ScheduleEEventMap
ScheduleEFormDefinition
result objects
mapping contract specs
```

### Commit 3 — Ledger-backed Schedule E query

```text
ordinary Receipt cash effects
receipt reversals
expense account postings
expense reversals
property/year scoping
```

### Commit 4 — Deposit and review policy

```text
exclude deposit receive/refund
flag deposit application
unmapped-event review items
```

### Commit 5 — Worksheet UI

```text
tax profile setup
year selector
worksheet
line/category presentation
drill-down
warnings
```

### Commit 6 — Acceptance/invariants

```text
unpaid rent
receipt
prepayment
overpayment
deposit
reversed expense
corrections
year boundaries
property isolation
```

### Commit 7 — Cleanup/docs/types

```text
delete old ScheduleESummaryQuery
RBS for typed tax core
documentation
full quality gate
```

---

# 62. Quality gate

Run:

```bash
bundle exec rspec

bundle exec rbs validate
bundle exec steep check

bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

If the tax-profile migration is added:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate
```

---

# 63. Milestone 9 done-when checklist

### Tax model

- [ ] `PropertyTaxProfile` exists.
- [ ] One profile per Property/tax year.
- [ ] Schedule E type is separate from `Property.asset_type`.
- [ ] `other` requires a description.
- [ ] Tax classification can differ between years.

### Income

- [ ] Unpaid rent Charge contributes `$0` to rents received.
- [ ] Ordinary Receipt contributes cash received.
- [ ] Prepayment contributes when received under the initial cash-received policy.
- [ ] Overpayment isn't artificially capped to charges.
- [ ] Receipt reversal cancels the original.
- [ ] Receipt correction nets to the replacement.
- [ ] Refundable security-deposit receipt contributes `$0`.
- [ ] Security-deposit refund contributes `$0`.
- [ ] Deposit application is explicitly reviewed rather than silently guessed.

### Expenses

- [ ] Expense reporting comes from mapped postings.
- [ ] Every system Expense account has an explicit mapping.
- [ ] Reversed Expense has zero net effect.
- [ ] Corrected Expense nets to replacement.
- [ ] `other` retains supporting detail.
- [ ] Depreciation isn't falsely reported as `$0`/complete.

### Architecture

- [ ] `TaxReporting::ScheduleEQuery` replaces the legacy source-table query.
- [ ] Schedule E line names aren't embedded in accounting models.
- [ ] Expense models don't know tax line numbers.
- [ ] Property physical type remains independent.
- [ ] All aggregate amounts use integer cents.
- [ ] `JournalEntry.occurred_on` controls report-year membership.
- [ ] Unmapped/review-required events are surfaced, not silently dropped.

### Core PRD acceptance

```text
Unpaid rent:
  Receivable affected          yes
  Schedule E cash received     no

Ordinary tenant Receipt:
  Schedule E cash received     yes

Refundable deposit received:
  Schedule E ordinary receipt  no

Reversed Expense:
  net Schedule E expense       zero
```

Those are the exact minimum M9 acceptance conditions in the PRD. 

The design choice I'd be most deliberate about is **not equating Schedule E line 3 with either `Rental Income` or generic Cash postings**. Rental Income is accrual-oriented and generic Cash includes deposits and bookkeeping reversals. For this model, ordinary `Receipt` accounting effects are the right initial source for cash-received rental income, while deposit events get their own explicit tax policy. That keeps M9 a projection over financial truth instead of introducing a second competing ledger.
