# Milestone 8 implementation plan

## 1. Objective

Replace operational reporting like this:

```text
Property
  -> Charges
  -> Receipts
  -> Expenses
  -> SecurityDepositTransactions
  -> combine/sort/recalculate
```

with:

```text
Property / Tenancy / Account
        ↓
Posting
        ↓
JournalEntry
        ↓
source record only for semantic explanation
```

The ledger answers:

```text
How much?
When?
Which account?
Which property/unit/tenancy/party?
What changed after reversal?
```

The domain source still answers:

```text
Why?
What kind of charge?
Who paid?
Which expense?
Which deposit application?
```

That is the PRD's intended boundary: domain records explain why, ledger records explain the financial effect. 

---

# 2. Milestone boundary

Implement:

- ledger-backed Property activity;
- ledger-backed Tenancy activity;
- Property accounting totals;
- read-only Account activity;
- current/as-of Tenant Receivable;
- current/as-of security-deposit liability;
- period/date filtering;
- accounting-detail drill-down;
- reversal/correction presentation;
- ledger-backed active reporting years;
- invariant/acceptance coverage;
- query indexes where justified.

Do **not** implement:

- `PropertyTaxProfile`;
- Schedule E account mapping;
- Schedule E cash-basis classification;
- tax-property classifications;
- depreciation;
- user-authored journal entries;
- editable accounting entries;
- cached balances/materialized projections.

Those belong to later milestones or are explicit non-goals. 

---

# 3. Establish the current transitional queries

The main remaining operational legacy is:

```ruby
Properties::FinancialItemsQuery
```

which currently fetches Charges, Receipts, Expenses, and SecurityDepositTransactions independently, then combines and sorts them. 

`Properties::ActiveYearsQuery` similarly derives reporting years from those four domain tables. 

Those are the primary Milestone 8 replacement targets.

Two important balances are **already ledger-backed**:

```text
Tenancies::BalanceQuery
    -> Tenant Receivable postings

Accounting::SecurityDepositBalanceQuery
    -> Security Deposits Held postings
``` 


So don't rewrite working accounting logic merely for churn. Consolidate/namescape it where useful.

---

# 4. Introduce a shared ledger scope

Create something like:

```text
Accounting::JournalEntryScope
```

or a private shared query helper.

It should accept:

```text
user:
property:
rentable_unit:
tenancy:
party:
account:
from:
through:
```

and build the query from:

```text
JournalEntry
JOIN postings
```

not from source tables.

For Property:

```sql
WHERE postings.property_id = ?
```

For Tenancy:

```sql
WHERE postings.tenancy_id = ?
```

Because one JournalEntry usually has multiple postings with the same dimension, select distinct journal entries.

Conceptually:

```ruby
JournalEntry
  .where(id: Posting.where(property_id: property.id).select(:journal_entry_id))
  .where(occurred_on: from..through)
```

Posting dimensions are already canonicalized from Tenancy → Unit → Property by `PostingBuilder`, so this is exactly what those dimensions were created for. 

---

# 5. Date semantics

Use:

```text
JournalEntry.occurred_on
```

as the accounting date everywhere.

Do not use:

```text
Charge.charge_date
Receipt.received_on
Expense.paid_on
SecurityDepositTransaction.occurred_on
```

independently inside reporting queries.

Those source fields cause the posting date, but after posting the immutable JournalEntry is the accounting authority.

The PRD explicitly requires as-of balances based on `JournalEntry.occurred_on`. 

---

# 6. Separate period activity from balances

This distinction is important.

### Period activity

For:

```text
2026-01-01 .. 2026-12-31
```

calculate postings whose JournalEntry occurs **inside** the period.

Examples:

```text
Cash in during period
Cash out during period
Expenses recognized during period
Rental income recognized during period
Receivable movement during period
Deposit-liability movement during period
```

### As-of balance

For:

```text
2026-12-31
```

calculate:

```text
all relevant postings <= 2026-12-31
```

Examples:

```text
Tenant Receivable balance
Security Deposits Held
Account closing balance
```

Do not accidentally define:

```text
Dec 31 receivable
= only December postings
```

---

# 7. Standardize date-range parsing

Create a small reporting value object/query helper, e.g.:

```text
Accounting::DateRange
```

Inputs:

```text
from
through
year
```

Rules:

```text
year only
    -> Jan 1 .. Dec 31

from + through
    -> explicit inclusive range

from only
    -> from .. today

through only
    -> beginning .. through

from > through
    -> invalid
```

Controllers should not duplicate date parsing.

Use actual `Date` values internally.

---

# 8. Property ledger query

Replace:

```text
Properties::FinancialItemsQuery
```

with:

```text
Accounting::PropertyLedgerQuery
```

as suggested by the PRD's query architecture. 

Input:

```ruby
property:
from:
through:
```

Return:

```text
Array<Accounting::ActivityRow>
```

ordered:

```text
occurred_on DESC
journal_entry.id DESC
```

or ascending if preserving the current UI feels better.

---

# 9. Define a stable ActivityRow

Do not make views understand every domain class and every accounting event.

Use something like:

```ruby
Accounting::ActivityRow = Data.define(
  :journal_entry,
  :occurred_on,
  :kind,
  :label,
  :description,
  :amount_cents,
  :property,
  :rentable_unit,
  :tenancy,
  :party,
  :source,
  :reversal,
  :corrected
)
```

The view consumes a projection rather than branching on four unrelated AR models.

This replaces the current `item[:type]`, `item[:amount]`, and `item[:object]` hash contract. 

---

# 10. Map accounting events to domain-friendly row types

Use `JournalEntry.event_type` plus its source.

Suggested projection:

```text
charge_posted + rent
    -> Rent

charge_posted + late_fee
    -> Late fee

charge_posted + reimbursement
    -> Reimbursement

charge_posted + other
    -> Charge

receipt_posted
    -> Payment

expense_posted
    -> Expense

deposit_received
    -> Security deposit received

deposit_refunded
    -> Security deposit refund

deposit_applied
    -> Security deposit applied

reversal
    -> Correction / Reversal
```

The PRD specifically wants domain-friendly ledger rows rather than making users read debit/credit lines. 

---

# 11. Derive displayed amounts from postings, not source amounts

A balanced JournalEntry's postings sum to zero, so there is no generic:

```text
journal_entry.amount
```

Define which ledger leg represents the user's activity amount.

Recommended mapping:

```text
charge_posted
    -> Tenant Receivable posting

receipt_posted
    -> Cash posting

expense_posted
    -> Cash posting

deposit_received
    -> Cash posting

deposit_refunded
    -> Cash posting

deposit_applied
    -> Tenant Receivable posting
```

Examples:

```text
Rent charge
  Tenant Receivable +200000
  display +$2,000 obligation

Receipt
  Cash +200000
  display +$2,000 cash

Expense
  Cash -30000
  display -$300 cash

Deposit refund
  Cash -50000
  display -$500 cash
```

Do not call:

```ruby
source.amount_cents
```

to calculate the financial amount.

The source can still provide description/category metadata.

---

# 12. Reversal display amounts

For:

```text
event_type = reversal
```

use:

```text
journal_entry.reversal_of
```

to identify the original accounting event.

Then derive the reversal display amount from the **reversal posting corresponding to the original event's display account**.

Example:

```text
Original Receipt
  Cash +$2,000

Reversal
  Cash -$2,000
```

Display:

```text
Payment               +$2,000
Payment correction    -$2,000
```

Do not suppress reversal rows from the ledger projection.

The PRD requires corrections to leave the original, reversal, and replacement visible. 

---

# 13. Correction chains in the property ledger

Example:

```text
Jan 1  Payment                    +$2,000
Jan 1  Correction of Payment      -$2,000
Jan 1  Replacement Payment        +$2,100
```

If the correction was intentionally dated later:

```text
Jan 1  original
Feb 5  reversal
```

the February reversal belongs in February activity.

The projection must obey ledger dates rather than retroactively hiding events because a domain source is now `voided?`.

---

# 14. Do not filter out reversed originals

This would be wrong:

```ruby
Receipt.active
Charge.active
Expense.active
```

inside the ledger query.

The accounting ledger already contains:

```text
original
+
reversal
```

and those net correctly.

Filtering the original merely because the source is voided would leave only the reversal and corrupt the report.

This is one of the biggest conceptual changes from the current domain-table projection.

---

# 15. Accounting detail drill-down

Add:

```text
Accounting entry
```

detail for an ActivityRow.

Could be:

```text
GET /journal_entries/:id
```

read-only.

Show:

| Account | Debit | Credit |
|---|---:|---:|
| Tenant Receivable | $2,000 | |
| Rental Income | | $2,000 |

Also show:

```text
Occurred on
Description
Property
Unit
Tenancy
Party
Source event
Reversal of / Reversed by
```

The PRD explicitly permits this as an audit/debug view while keeping bookkeeping mechanics out of normal workflows. 

---

# 16. JournalEntry remains read-only

Routes:

```ruby
resources :journal_entries, only: :show
```

No:

```text
new
create
edit
update
destroy
```

Milestone 8 is a reporting milestone, not a general ledger editor.

---

# 17. Tenancy activity query

Create:

```text
Accounting::TenancyActivityQuery
```

Input:

```text
tenancy
from
through
```

It should select JournalEntries through:

```text
postings.tenancy_id
```

and use the same `ActivityRow` projector.

This gives one coherent running-account statement containing:

```text
Rent
Late fee
Reimbursement
Payment
Deposit applied
Reversals/corrections
```

Expenses should normally not appear because property Expense postings have no Tenancy dimension.

Security-deposit **receive/refund** postings do have a Tenancy dimension, so decide whether the main tenancy account statement includes them.

My recommendation:

- Tenancy **financial activity**: include all tenancy-dimensional JournalEntries.
- Tenant **receivable statement**: filter to JournalEntries having a Tenant Receivable posting.

Expose these as two explicit concepts rather than silently mixing liability activity into the A/R statement.

---

# 18. Tenant account statement

Create:

```text
Accounting::TenantReceivableActivityQuery
```

or allow:

```ruby
TenancyActivityQuery(account_key: "tenant_receivable")
```

Rows should include:

```text
Rent charge            +$2,000
Payment                -$750
Late fee                  +$50
Deposit applied          -$500
```

with a running balance:

```text
Balance after row
```

This directly answers why the current tenant balance is what it is.

---

# 19. Running balance implementation

For a filtered period:

```text
from = 2026-07-01
through = 2026-07-31
```

first calculate:

```text
opening balance
= all Tenant Receivable postings < from
```

Then walk period postings chronologically:

```text
opening + row 1
        + row 2
        ...
```

Return:

```text
opening_balance_cents
rows
closing_balance_cents
```

Do not calculate the running balance from Charges/Receipts.

---

# 20. Replace/currently rename Tenancy balance query

Current `Tenancies::BalanceQuery` already correctly sums the Tenant Receivable account's postings by tenancy/as-of. 

I'd move the implementation to:

```text
Accounting::TenancyBalanceQuery
```

to match the PRD, while retaining convenience methods:

```ruby
tenancy.current_balance
tenancy.balance_as_of(date)
```

The model should simply delegate.

Then delete the old query rather than keep two implementations.

---

# 21. Tenant balance acceptance

Keep/pin:

```text
Rent                +$2,000
Payment               -$750
Late fee               +$50
Deposit applied        -$500
--------------------------------
Tenant Receivable      $800
```

Query result:

```text
+80000 cents
```

The same sequence rendered as activity must end with the same `$800` closing balance.

---

# 22. Security deposit balance

Current:

```text
Accounting::SecurityDepositBalanceQuery
```

already reads the liability postings and converts the credit-normal sign to a positive held amount. 

Keep that accounting logic.

Expand tests for:

```text
tenancy scope
property scope
user scope
as_of
```

if any are missing.

---

# 23. Security deposit activity

Add:

```text
Accounting::SecurityDepositActivityQuery
```

or use generic AccountActivityQuery scoped to:

```text
account_key = security_deposits_held
tenancy/property
```

Display:

```text
Received     +$2,000 held
Applied        -$500 held
Refunded       -$750 held
Closing held    $750
```

The raw ledger signs are the opposite for liability credits, so presentation should use **natural balance semantics**.

---

# 24. Define natural balance semantics once

Yanushi's raw convention is:

```text
positive = debit
negative = credit
``` 


For reporting:

```text
asset
expense
    natural balance = raw signed balance

liability
equity
income
    natural balance = -raw signed balance
```

Create a small utility:

```text
Accounting::NaturalBalance
```

or:

```ruby
Account#natural_balance_sign
```

Prefer a query/presentation helper over embedding sign inversion throughout views.

---

# 25. Generic account balance query

Create:

```text
Accounting::AccountBalanceQuery
```

Inputs:

```text
account
as_of
property
rentable_unit
tenancy
party
```

Output:

```text
raw_balance_cents
natural_balance_cents
```

This can replace duplicated logic inside:

```text
TenancyBalanceQuery
SecurityDepositBalanceQuery
```

if the abstraction stays simple.

I would implement the generic primitive and let the named domain queries delegate to it, rather than deleting the domain-friendly queries.

---

# 26. Generic account activity query

Create:

```text
Accounting::AccountActivityQuery
```

Input:

```text
account
from
through
property optional
rentable_unit optional
tenancy optional
party optional
```

Return each Posting—not each JournalEntry—because account activity is specifically a ledger-line view.

Result row:

```text
occurred_on
journal_entry
description
debit_cents
credit_cents
running_raw_balance_cents
running_natural_balance_cents
dimensions
```

---

# 27. Account reporting UI

Add a read-only accounting page:

```text
/accounting/accounts
```

or:

```text
/accounts
```

Since arbitrary account management remains a non-goal, make it clearly reporting-only.

Index:

```text
Account
Type
Current balance
```

Example:

```text
Cash                       Asset       $25,400
Tenant Receivable          Asset        $3,250
Security Deposits Held     Liability    $5,000
Rental Income              Income      $42,000
Utilities                  Expense      $2,300
```

---

# 28. Account detail page

For one Account:

```text
Opening balance
Activity during period
Closing balance
```

Rows:

```text
Date
Description
Property
Unit
Tenancy
Party
Debit
Credit
Balance
```

Allow filters:

```text
from
through
property
tenancy
```

All user-scoped server-side.

Never look up an Account only by client-supplied ID without:

```ruby
authenticated_user.accounts.find(...)
```

The PRD explicitly requires accounting query authorization to remain user-scoped. 

---

# 29. Property summary query

Create:

```text
Accounting::PropertySummaryQuery
```

Inputs:

```text
property
from
through
```

Return two groups.

### Period activity

```text
cash_in_cents
cash_out_cents
net_cash_movement_cents

income_recognized_cents
operating_expense_cents

tenant_receivable_change_cents
security_deposit_liability_change_cents
```

### Closing balances

```text
tenant_receivable_cents
security_deposits_held_cents
```

All of these come from postings.

---

# 30. Define property cash totals from the Cash account

For a period:

```text
cash_in
= sum positive Cash postings

cash_out
= -sum negative Cash postings

net_cash
= sum all Cash postings
```

This means:

```text
ordinary payment      cash in
deposit received      cash in
expense               cash out
deposit refund        cash out
```

That's correct operational cash movement.

Do **not** label this:

```text
Rents received
```

because security deposits are included and tax classification comes in Milestone 9.

Use:

```text
Cash received
Cash paid
Net cash movement
```

---

# 31. Accrual income totals

For account types:

```text
income
```

period natural activity is:

```text
-sum(postings.amount_cents)
```

Display this as:

```text
Income recognized
```

or break down:

```text
Rental income
Late-fee income
Reimbursement income
Other tenant income
```

Do **not** call it:

```text
Cash income
Schedule E rent
Rents received
```

A rent Charge credits income before receipt, and the PRD explicitly calls out that distinction. 

---

# 32. Expense totals

For accounts with:

```text
account_type = expense
```

period natural activity is the debit sum.

Return breakdown keyed by stable account key:

```text
expense_advertising
expense_auto_travel
expense_cleaning_maintenance
...
```

Again, this is **bookkeeping expense activity**, not yet Schedule E mapping.

---

# 33. Property receivable balance

Compute:

```text
Tenant Receivable postings
WHERE property_id = property.id
AND occurred_on <= through
```

That gives the combined outstanding receivable across the property's tenancies.

Test that:

```text
Unit A owes $500
Unit B has $100 credit

Property Tenant Receivable = $400 debit
```

while the individual Tenancy balances remain independently available.

---

# 34. Property deposit liability

Continue using ledger postings:

```text
Security Deposits Held
WHERE property_id = property.id
```

The Property page already shows a current ledger-backed security-deposit liability; Milestone 8 should integrate that into the unified PropertySummaryQuery rather than keep it as an isolated controller calculation. 

---

# 35. Property activity page/view

Replace the current four-table financial timeline with the new PropertyLedgerQuery.

The user-visible table can remain approximately:

```text
Date
Type
Details
Amount
```

but every row must originate from a JournalEntry.

The current view has substantial type-specific branching against Charge/Receipt/Expense/SecurityDepositTransaction. 

Move that semantic conversion into the projection object/helper.

---

# 36. Property summary cards

Above the activity table show something like:

```text
Period
Cash received             $12,500
Cash paid                  $4,100
Net cash movement          $8,400

Income recognized         $11,750
Operating expenses         $3,800

As of Dec 31
Tenant receivable          $2,250
Security deposits held     $4,000
```

This makes the accrual/cash/balance distinctions explicit instead of presenting one vague "Income" number.

---

# 37. Date-filtered Property reporting

Replace the current year-only input with:

```text
Year preset
From
Through
```

A simple first UI could offer:

```text
2026
2025
Custom
```

The query layer should already support arbitrary dates even if the UI initially emphasizes years.

---

# 38. Ledger-backed active years

Replace `Properties::ActiveYearsQuery` source-table scans with:

```text
JournalEntry.occurred_on
WHERE EXISTS posting for property
```

For PostgreSQL:

```text
DISTINCT EXTRACT(YEAR FROM journal_entries.occurred_on)
```

This naturally includes:

```text
reversal-only year
```

which the current source-record implementation can miss.

That is important.

Example:

```text
2025 original Expense
2026 later reversal
```

2026 must appear as a Property ledger year even if no 2026 Expense source was created.

---

# 39. Reversal-year regression

Explicitly test:

```text
Dec 20, 2025
Expense $500

Jan 10, 2026
Void with Jan 10 reversal
```

Expected:

```text
active years = [2025, 2026]

2025 ledger:
  Expense -$500

2026 ledger:
  Reversal +$500
```

This is a good proof that the report really comes from JournalEntries.

---

# 40. Same-date correction regression

For correction semantics that reverse on the original date:

```text
Jan 5  original Receipt   +$2,000
Jan 5  reversal           -$2,000
Jan 5  replacement        +$2,100
```

Period net Cash:

```text
+$2,100
```

and net Tenant Receivable:

```text
-$2,100
```

The activity ledger still contains all three entries.

---

# 41. Later-date waiver regression

For an ordinary Charge waiver:

```text
May 10 Late fee      +$50 A/R
May 15 reversal      -$50 A/R
```

Expected:

```text
balance as of May 12 = $50
balance as of May 15 = $0
```

and activity retains both events.

This protects the void-versus-correction distinction established earlier.

---

# 42. Tenancy page: add recent account activity

The PRD explicitly asks the Tenancy page to show recent account activity alongside current balance. 

The current page separately shows all Charges and Receipts and a ledger-backed current balance. 

Add a concise:

```text
Recent Account Activity
```

based on Tenant Receivable postings:

```text
Aug 1   Rent                +$2,000      $2,000 owed
Aug 3   Payment             -$1,500        $500 owed
Aug 10  Late fee               +$50        $550 owed
```

Link to:

```text
View full account activity
```

---

# 43. Do not remove domain history sections

Milestone 8 should **not** replace:

```text
Charges & Obligations
Payments & Receipts
Security Deposit history
```

with bare accounting rows.

Those tables answer semantic/domain questions and provide lifecycle actions.

The new Tenancy activity is an additional **financial statement projection**.

This preserves the PRD principle that accounting must not replace the rental model. 

---

# 44. Full Tenancy statement route

Suggested route:

```ruby
resources :tenancies do
  member do
    get :account_activity
  end
end
```

Or:

```text
/tenancies/:id/statement
```

Show:

```text
Opening balance
Activity
Closing balance
```

Date range controls included.

---

# 45. Explain sign semantics at the presentation boundary

For tenancy statement:

```text
positive Tenant Receivable
    = amount owed

negative Tenant Receivable
    = credit
```

The current balance view already uses exactly this interpretation. 

Do not change posting signs just to make UI values prettier.

---

# 46. Reversal/source navigation

Activity rows should expose:

```text
View source
View accounting entry
```

Examples:

```text
Rent -> Charge
Payment -> Receipt
Expense -> Expense
Deposit -> SecurityDepositTransaction
Reversal -> original JournalEntry/source
```

For corrections:

```text
original -> reversal -> replacement
```

should be navigable.

---

# 47. Source records are explanatory only

A ledger row may safely ask its source:

```text
charge.charge_kind
charge.description
receipt.payer_party
expense.expense_kind
deposit_transaction.transaction_kind
```

But report totals must not ask:

```text
source.amount_cents
source.active?
```

to reconstruct accounting.

That distinction should be explicitly documented and tested.

---

# 48. Handle missing/broken polymorphic source defensively

Under normal domain constraints, posted sources cannot be hard-deleted.

Still, an accounting query should not crash completely if a source cannot load.

Fallback:

```text
label = JournalEntry.event_type.titleize
description = JournalEntry.description
```

Accounting truth remains in the JournalEntry/Postings.

Do not silently omit the entry because its explanatory source is unavailable.

---

# 49. Query performance

The PRD says correctness wins over premature aggregation, but queries should use indexed ledger dimensions. 

Audit existing indexes for:

```text
postings.account_id
postings.property_id
postings.rentable_unit_id
postings.tenancy_id
postings.party_id
postings.journal_entry_id
journal_entries.occurred_on
```

Then add composite indexes only for actual query shapes.

Likely candidates:

```text
postings(property_id, journal_entry_id)
postings(tenancy_id, account_id, journal_entry_id)
postings(account_id, journal_entry_id)
journal_entries(occurred_on, id)
```

Measure/explain-query before adding broad index combinations.

---

# 50. Avoid N+1s in activity queries

Property activity may contain several polymorphic source types.

Preload:

```text
JournalEntry.postings.account
JournalEntry.source
JournalEntry.reversal_of
reversal_of.source
```

where Rails permits.

The view should not generate one query per row/account/source.

Add query-count coverage only if the app already has a convention for it; otherwise verify manually.

---

# 51. Property model delegation

Replace:

```ruby
property.financial_items(year)
```

with something explicitly ledger-oriented, e.g.:

```ruby
property.accounting_activity(from:, through:)
property.accounting_summary(from:, through:)
```

or call query objects directly from the controller.

I slightly prefer direct query objects in controllers for reports; the model doesn't need to become a reporting façade.

---

# 52. Controller boundary

`PropertiesController#show` currently loads:

```text
expenses
charges
receipts
```

mainly to construct financial reporting. 

After the ledger projection lands, stop eager-loading those associations solely for the financial table.

Instead:

```ruby
@activity =
  Accounting::PropertyLedgerQuery.call(...)

@summary =
  Accounting::PropertySummaryQuery.call(...)
```

Keep domain associations only where other page sections need them.

---

# 53. No manual total SQL in controllers/views

Do not put:

```ruby
postings.where(...).sum(...)
```

in the controller.

Do not put:

```erb
<%= entries.sum { ... } %>
```

in the view.

The PRD explicitly calls for accounting/reporting query objects and warns against large financial expressions in controllers/views. 

---

# 54. Schedule E remains deliberately separate

Current `Properties::ScheduleESummaryQuery` still derives rents and expenses from Receipt/Expense records. 

**Do not turn that into `PropertySummaryQuery`.**

Milestone 8 should leave it as a known transitional tax query because Milestone 9 explicitly implements:

```text
PropertyTaxProfile
Schedule E mapping
cash-received semantics
deposit exclusion
reversal handling
``` 


Document this exception so a reviewer doesn't mistake it for unfinished Milestone 8 operational reporting.

---

# 55. Don't call accrual Rental Income “rents received”

This is worth an explicit regression.

Given:

```text
Jan 1 Rent charge $2,000
no payment
```

Ledger:

```text
Tenant Receivable   +$2,000
Rental Income       -$2,000
Cash                      $0
```

Milestone 8 Property Summary may say:

```text
Income recognized      $2,000
Tenant receivable      $2,000
Cash received              $0
```

It must **not** say:

```text
Rents received $2,000
```

Milestone 9 decides tax cash-received treatment. 

---

# 56. Deposit cash regression

Given:

```text
Security deposit received $2,000
```

Property summary:

```text
Cash received             $2,000
Deposit liability          $2,000
Tenant Receivable              $0
Income recognized              $0
```

This proves the summary is accounting-correct without pretending all cash receipts are rental income.

---

# 57. Expense regression

Given:

```text
Utility Expense $300
```

Expected:

```text
Cash paid             $300
Operating expense     $300
Net cash movement    -$300
```

Then reverse it in the same period:

```text
period operating expense = $0
period net cash movement = $0
```

No `Expense.active` filtering should be necessary.

---

# 58. Reimbursement regression

Given:

```text
Expense                         $300
Reimbursement Charge            $300
Tenant payment                  $300
```

Expected ledger summary:

```text
Operating expenses              $300
Reimbursement income recognized $300
Cash paid                       $300
Cash received                   $300
Tenant Receivable                 $0
```

All three domain events remain independently visible, which is a required accounting scenario in the PRD. 

---

# 59. Multifamily isolation

Property with:

```text
Unit A / Tenancy A
Unit B / Tenancy B
```

Post:

```text
A Rent       $2,000
B Rent       $1,500
A Payment    $1,000
B Payment    $1,500
```

Expected:

```text
Property receivable    $1,000

Tenancy A              $1,000 owed
Tenancy B                  $0

A account statement contains no B postings
B account statement contains no A postings
```

This proves dimensions, not source associations, drive isolation.

---

# 60. Joint-tenancy payer identity

Given one Tenancy with Alice and Bob:

```text
Rent $2,000
Bob pays $750
```

Tenant statement:

```text
Rent                   +$2,000
Payment — Bob            -$750
Balance                 $1,250
```

The same Tenancy Receivable account moves regardless of which Party paid, while the Party dimension preserves payer identity. That is a required architecture property. 

---

# 61. Account activity acceptance

For Cash account:

```text
Receipt                  +$2,000 debit
Deposit received         +$1,500 debit
Expense                    $300 credit
Deposit refund             $500 credit
```

Natural Cash balance change:

```text
+$2,700
```

Account detail should reproduce this exactly from postings.

---

# 62. Date boundary tests

Pin inclusive accounting dates:

```text
from = Jan 1
through = Jan 31
```

Include:

```text
Jan 1
Jan 31
```

Exclude:

```text
Dec 31
Feb 1
```

For balances:

```text
as_of Jan 31
```

includes Jan 31.

---

# 63. Future source dates aren't the reporting layer's concern

Reporting should not impose:

```text
occurred_on <= today
```

itself.

Posting/domain services own financial-event date validation.

Reporting simply reports immutable ledger entries that exist.

This keeps query logic from becoming a second business-rule engine.

---

# 64. Portfolio-level primitive

Even if no portfolio dashboard is added yet, structure generic balance/account queries so:

```text
user:
```

scope works without Property/Tenancy.

This makes the PRD invariant:

```text
portfolio posting totals remain balanced
```

easy to test and gives a clean base for future reporting. 

---

# 65. Invariant spec: reporting agrees with postings

For generated domain events:

```ruby
expect(summary.tenant_receivable_cents).to eq(
  ledger_postings_for("tenant_receivable").sum(:amount_cents)
)
```

Likewise:

```text
security deposit
cash
expenses
income
```

The expected value should come directly from a deliberately simple Posting sum, **not** from Charges/Receipts/Expenses.

---

# 66. Invariant spec: domain-source mutation cannot change reporting

Posted source financial fields are already immutable, but pin the architectural boundary.

Given one posted Charge:

```text
ledger report = $2,000
```

Changing harmless source presentation metadata—where allowed—must not change ledger totals.

A report should change only because another JournalEntry/Postings were created.

---

# 67. Global balance invariant

Retain:

```text
for every JournalEntry
sum(postings.amount_cents) == 0
```

and add reporting-sequence/property-style tests generating combinations of:

```text
charges
receipts
fees
expenses
deposit transactions
reversals
```

then verify:

```text
Tenancy balance
== Tenant Receivable postings

Deposit balance
== liability postings

Property totals
== scoped posting sums
```

The PRD explicitly says these invariant tests are more valuable than merely unit-testing SQL implementation details. 

---

# 68. RBS / Steep

Add signatures for roughly:

```text
Accounting::DateRange

Accounting::ActivityRow
Accounting::ActivityProjector

Accounting::PropertyLedgerQuery
Accounting::PropertySummaryQuery

Accounting::TenancyActivityQuery
Accounting::TenancyBalanceQuery

Accounting::AccountActivityQuery
Accounting::AccountBalanceQuery

Accounting::SecurityDepositBalanceQuery
```

and controllers/presenters introduced for account activity.

Keep money outputs in:

```text
Integer cents
```

inside queries.

Convert to `BigDecimal`/formatted currency only at convenience/presentation boundaries.

---

# 69. Documentation

Add:

```text
documentation/double_entry_accounting/
  implementation_plan_milestone_8.md
```

Document explicitly:

1. ledger is financial reporting source of truth;
2. source records remain semantic explanation;
3. difference between period activity and as-of balances;
4. raw debit/credit sign convention;
5. natural balance display;
6. Property dimensions;
7. Tenancy dimensions;
8. reversal presentation;
9. accrual income vs cash movement;
10. Schedule E remains Milestone 9.

That last item will prevent accidental tax semantics from leaking into the operational summary.

---

# 70. Stale-query sweep

After implementation:

```bash
rg -n \
  'FinancialItemsQuery|financial_items|ActiveYearsQuery' \
  app spec sig documentation
```

Expected:

```text
old domain-table financial projection gone
```

Then search:

```bash
rg -n \
  '\.charges.*sum|\.receipts.*sum|\.expenses.*sum|security_deposit_transactions.*sum' \
  app/queries app/controllers app/views
```

Every remaining hit should have a deliberate explanation—most notably the temporary Schedule E implementation pending Milestone 9.

---

# 71. Explicit Schedule E exception

I would put a comment/documentation note near the remaining query:

```text
Properties::ScheduleESummaryQuery is intentionally source-event-based
until Milestone 9 introduces the explicit tax reporting projection.
Do not reuse it for operational accounting totals.
```

That keeps the Milestone 8 completion criterion precise.

---

# 72. Suggested commit sequence

### Commit 1 — Reporting primitives

```text
Accounting::DateRange
AccountBalanceQuery
AccountActivityQuery
natural-balance helper
specs
```

### Commit 2 — Property ledger

```text
ActivityRow/projector
PropertyLedgerQuery
reversal projection
accounting-entry detail
```

### Commit 3 — Property totals

```text
PropertySummaryQuery
cash in/out
income activity
expense activity
receivable balance
deposit liability
```

### Commit 4 — Property UI cutover

```text
replace FinancialItemsQuery
replace ActiveYearsQuery
date filtering
summary cards
activity ledger
```

### Commit 5 — Tenancy activity

```text
Accounting::TenancyBalanceQuery
TenantReceivableActivityQuery
opening/running/closing balance
recent activity
statement UI
```

### Commit 6 — Account reporting UI

```text
read-only account index
account activity
dimension/date filters
```

### Commit 7 — Invariants/performance

```text
corrections
reversals
multifamily
joint tenancy
deposit
reimbursement
date boundaries
indexes
query efficiency
```

### Commit 8 — Types/docs/cleanup

```text
RBS
Steep
documentation
stale-query sweep
quality gate
```

---

# 73. Manual smoke test

Use one Property with two Units.

### Unit A

```text
Rent charge                 $2,000
Payment — Alice             $1,500
Late fee                       $50
Deposit received            $2,000
Deposit applied               $300
```

### Unit B

```text
Rent charge                 $1,500
Payment — Bob               $1,500
```

### Property

```text
Utility expense               $400
```

Verify:

```text
Tenancy A receivable
= 2000 - 1500 + 50 - 300
= $250

Tenancy B receivable
= $0

Property receivable
= $250

Deposit held
= $1,700
```

Cash:

```text
Alice payment       +1500
deposit received    +2000
Bob payment         +1500
utility expense      -400
-------------------------
net cash movement   +4600
```

Then correct Alice's `$1,500` payment to `$1,600`.

Verify activity contains:

```text
original
reversal
replacement
```

and:

```text
Tenancy A receivable = $150
```

without any source-table arithmetic.

---

# 74. Quality gate

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

Also:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate
```

if any reporting indexes/migrations are added.

---

# 75. Milestone 8 done-when checklist

### Ledger source of truth

- [ ] Property activity originates from JournalEntries/Postings.
- [ ] Tenancy activity originates from JournalEntries/Postings.
- [ ] Property totals originate from Postings.
- [ ] Active financial years originate from JournalEntry dates.
- [ ] No operational balance is reconstructed from Charge/Receipt/Expense tables.
- [ ] Source records are used only to explain ledger events.

### Balances

- [ ] Current Tenancy receivable comes from `tenant_receivable`.
- [ ] As-of Tenancy receivable works.
- [ ] Property receivable works.
- [ ] Tenancy deposit held comes from `security_deposits_held`.
- [ ] Property deposit held works.
- [ ] Account balances support as-of dates.
- [ ] Natural liability/income signs are presented correctly.

### Activity

- [ ] Property ledger supports date range.
- [ ] Tenancy statement supports date range.
- [ ] Account activity supports date range.
- [ ] Opening/closing balances are correct.
- [ ] Reversals are visible.
- [ ] Corrected originals remain visible.
- [ ] Replacement sources remain visible.
- [ ] Later-period reversals appear in the later period.

### Property totals

- [ ] Cash received is ledger-derived.
- [ ] Cash paid is ledger-derived.
- [ ] Net cash movement is correct.
- [ ] Income recognized is ledger-derived.
- [ ] Operating expenses are ledger-derived.
- [ ] Receivable movement/balance is ledger-derived.
- [ ] Deposit liability movement/balance is ledger-derived.
- [ ] Deposits are not mislabeled as rental income.

### UI

- [ ] Property page uses ledger activity.
- [ ] Property page shows accounting summary.
- [ ] Tenancy page shows recent account activity.
- [ ] Full Tenancy statement exists.
- [ ] Read-only account activity exists.
- [ ] JournalEntry accounting detail exists.
- [ ] No debit/credit knowledge is required for ordinary rental workflows.

### Boundary with Milestone 9

- [ ] Accrual Rental Income is not labeled "rents received."
- [ ] Cash movement is not presented as Schedule E income.
- [ ] Current Schedule E query is explicitly transitional.
- [ ] No `PropertyTaxProfile` work is pulled forward.
- [ ] Final Schedule E mapping remains Milestone 9.

The biggest implementation risk is **reversal handling**. A ledger-backed report must not reproduce the old source-record habit of filtering to `.active` records. The correct report contains the original posting and the reversing posting; the net balance falls out naturally. Once that rule is followed consistently, most of Milestone 8 becomes simpler than the current four-table reporting code.

The second important decision is to keep **operational accounting and tax reporting separate**. A rent Charge legitimately creates accrual Rental Income before cash arrives, while Milestone 9 will decide what counts as Schedule E cash received. Milestone 8 should make that difference obvious rather than trying to solve both layers at once.
