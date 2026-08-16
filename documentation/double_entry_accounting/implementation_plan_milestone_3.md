# Implementation Plan: Milestone 3 — Charges and Tenant Receivables

## Objective

Implement Milestone 3 of the Rental Domain and Double-Entry Accounting Architecture.

At the end of this milestone:

```text
RentTerm
    │
    ▼
Charge(kind: rent)
    │
    ▼
JournalEntry
    ├── Dr Tenant Receivable
    └── Cr Rental Income
```

and:

```text
Charge(kind: late_fee)
    │
    ▼
JournalEntry
    ├── Dr Tenant Receivable
    └── Cr Late Fee Income
```

and:

```text
Expense
    │
    ▼
Charge(kind: reimbursement)
    │
    ▼
JournalEntry
    ├── Dr Tenant Receivable
    └── Cr Reimbursement Income
```

must all work through the accounting foundation established in Milestone 2.

`ScheduledRent` and `TenantCharge` must be removed.

Tenancy balance must become:

```text
sum(
  Tenant Receivable postings
  for this tenancy
  through the requested accounting date
)
```

rather than a reconstruction from domain tables.

The PRD defines Milestone 3 as implementing `Charge`, rent-charge generation, fee and reimbursement charges, charge posting, and ledger-backed tenancy balances, replacing `ScheduledRent`, `TenantCharge`, and the legacy balance query.

---

# 1. Milestone boundary

Implement:

- `Charge`
- rent-charge generation
- manual fee charges
- reimbursement charges
- charge posting
- charge voiding through journal reversal
- ledger-backed tenancy balances
- automatic generation of due rent charges
- replacement of `ScheduledRent`
- replacement of `TenantCharge`
- removal of `Tenancies::BalanceQuery`
- a temporary ledger adapter for legacy `TenantPayment`

Do **not** implement:

- `Receipt`
- payer identity on payments
- receipt allocation
- payment correction/replacement domain
- security deposits
- expense accounting
- expense journal posting
- property financial reporting from the ledger
- Schedule E changes
- tax-basis reporting
- general journal-entry UI
- automatic late-fee assessment
- prorated rent
- unapplied-cash liability accounting

Milestone 4 will replace the temporary `TenantPayment` bridge with the real `Receipt` model.

---

# 2. Why the temporary TenantPayment ledger bridge is required

The architectural milestone split has one dependency problem.

Milestone 3 says tenant balance is ledger-backed.

Milestone 4 says `Receipt` replaces `TenantPayment`.

The current application still records payments as `TenantPayment`, and the current balance query includes those payments directly.

If Milestone 3 moved charges to the ledger but continued reading payments directly from `tenant_payments`, the result would be a hybrid balance:

```text
ledger charges - legacy payments
```

That would violate the purpose of establishing Tenant Receivable as the authoritative subledger.

Therefore Milestone 3 must temporarily post newly-created `TenantPayment` records as:

```text
Dr Cash
Cr Tenant Receivable
```

The domain object remains `TenantPayment` until Milestone 4.

This bridge is intentionally temporary.

Do not add payer identity or redesign the payment model during this milestone.

---

# 3. Establish the baseline

Before modifying code:

```bash
git status --short

bundle exec rspec
bundle exec rbs validate
bundle exec steep check
bin/rubocop
bin/brakeman --no-pager
```

Record pre-existing failures.

Then inventory the legacy charge/balance implementation:

```bash
rg -n \
  'ScheduledRent|scheduled_rent|scheduled_rents|TenantCharge|tenant_charge|tenant_charges|Tenancies::BalanceQuery|total_debits|total_credits|current_balance|balance_as_of' \
  app config db spec sig documentation
```

Also inventory every way a payment can be persisted:

```bash
rg -n \
  'TenantPayment\.(new|create|create!)|tenant_payments\.(new|build|create|create!)|\.save!?|\.update!?' \
  app/services app/controllers db/seeds.rb
```

Do not assume `TenantPaymentsController` is the only creation path. Payment ingestion must also be traced.

---

# 4. Fixed accounting semantics

Use the Milestone 2 signed-posting convention:

```text
positive = debit
negative = credit
```

Charge posting rules are fixed:

## Rent

```text
Dr Tenant Receivable    +amount
Cr Rental Income        -amount
```

## Late fee

```text
Dr Tenant Receivable    +amount
Cr Late Fee Income      -amount
```

## Reimbursement

```text
Dr Tenant Receivable    +amount
Cr Reimbursement Income -amount
```

These are the posting rules specified by the architecture PRD.

Both sides carry:

```text
property
rentable_unit
tenancy
```

through the existing `PostingBuilder` tenancy dimension derivation.

No `Party` dimension belongs on a charge.

---

# 5. Tenant balance sign convention

Change tenancy balance to match the accounting subledger:

```text
positive balance = tenant owes landlord
zero             = settled
negative balance = tenant has credit
```

Do not invert the accounting query merely to preserve the old UI convention.

The current UI treats a positive balance as tenant credit and negative as amount owed, so the presentation and payment-prefill code must change together with the query.

Internally prefer cents:

```text
balance_cents_as_of(date)
current_balance_cents
```

For compatibility with currency helpers, a convenience dollar method may return:

```ruby
BigDecimal(balance_cents.to_s) / 100
```

but financial aggregation itself must remain integer cents.

---

# 6. Create the `charges` table

Create a migration with:

```text
charges

id
tenancy_id               NOT NULL
charge_kind               NOT NULL
amount_cents              BIGINT NOT NULL

charge_date               NOT NULL
due_on                    NOT NULL
description

rent_term_id              NULL
source_expense_id         NULL

service_period_start      NULL
service_period_end        NULL

posted_at                 NULL
voided_at                 NULL
superseded_by_id          NULL

created_at                NOT NULL
updated_at                NOT NULL
```

Add foreign keys:

```text
tenancy_id        -> tenancies
rent_term_id      -> rent_terms
source_expense_id -> expenses
superseded_by_id  -> charges
```

Add indexes on:

```text
tenancy_id
charge_kind
charge_date
due_on
rent_term_id
source_expense_id
service_period_start
voided_at
```

---

# 7. Charge database constraints

Add straightforward database checks:

```text
amount_cents > 0
```

and:

```text
service_period_end IS NULL
OR service_period_start IS NULL
OR service_period_end >= service_period_start
```

Restrict `charge_kind` to:

```text
rent
late_fee
reimbursement
other
```

Use the same string-backed enum/check-constraint approach already used elsewhere.

---

# 8. Rent-generation uniqueness

There must never be two simultaneously-live rent charges for the same tenancy service period.

Add a partial unique index approximately equivalent to:

```text
UNIQUE (
  tenancy_id,
  service_period_start
)
WHERE
  charge_kind = 'rent'
  AND voided_at IS NULL
```

This is stronger than relying only on the journal-entry source-event uniqueness because two concurrent generators could otherwise create two different `Charge` source records.

A voided charge no longer occupies the live uniqueness key, allowing an explicitly-corrected replacement to be generated later.

The PRD requires rent generation to have its own uniqueness protection.

---

# 9. Implement `Charge`

Create:

```text
app/models/charge.rb
```

Associations:

```ruby
belongs_to :tenancy
belongs_to :rent_term, optional: true

belongs_to :source_expense,
  class_name: "Expense",
  optional: true

belongs_to :superseded_by,
  class_name: "Charge",
  optional: true

has_one :superseded_charge,
  class_name: "Charge",
  foreign_key: :superseded_by_id
```

Do not use `dependent: :destroy` for accounting-related associations.

Implement:

```ruby
def accounting_user
  tenancy&.accounting_user
end
```

---

# 10. Charge validations

Common validations:

```text
tenancy required
valid charge_kind required
amount_cents > 0
charge_date required
due_on required
```

Validate ownership consistency.

For any `source_expense`:

```text
source_expense.accounting_user == tenancy.accounting_user
```

and:

```text
source_expense.property_id == tenancy.property.id
```

A reimbursement for Property A must not create a receivable against a tenancy in Property B.

---

# 11. Kind-specific Charge invariants

## Rent

Require:

```text
rent_term_id
service_period_start
service_period_end
```

Require:

```text
rent_term.tenancy_id == tenancy_id
```

Require the service period to lie within:

```text
tenancy bounds
rent term bounds
```

Require:

```text
source_expense_id == nil
```

## Reimbursement

Require:

```text
source_expense_id
```

Require:

```text
rent_term_id == nil
service_period_start == nil
service_period_end == nil
```

## Late fee

Require:

```text
rent_term_id == nil
source_expense_id == nil
```

No landlord expense is necessary.

## Other

Require neither rent term nor expense.

---

# 12. Money helper

If the existing forms benefit from it, give `Charge` an `amount` virtual accessor following the `RentTerm` pattern:

```ruby
charge.amount
charge.amount = "123.45"
```

but persist only:

```text
amount_cents
```

Invalid currency input must become model validation failure rather than silently producing a meaningful financial amount.

Prefer a dedicated money parser helper if the existing `RentTerm#amount=` behavior cannot distinguish invalid input from zero cleanly.

---

# 13. Posted Charge immutability

A posted charge is a historical financial source event.

Once:

```text
posted_at.present?
```

normal model updates must not alter:

```text
tenancy_id
charge_kind
amount_cents
charge_date
due_on
description
rent_term_id
source_expense_id
service_period_start
service_period_end
```

Permitted lifecycle changes after posting are limited to:

```text
voided_at
superseded_by_id
```

Do not provide an ordinary edit/update controller action for posted charges.

Corrections happen through:

```text
reverse old charge
create replacement charge
```

not:

```text
UPDATE charges SET amount_cents = ...
```

---

# 14. No committed unposted charges

`posted_at` may be nullable at the schema level because the domain service must persist the source before `Accounting::PostEntryService` can use it.

However, application code must maintain this invariant:

```text
a successfully committed Charge is posted
```

Charge creation and accounting posting must occur in one outer database transaction.

If ledger posting fails:

```text
Charge creation rolls back
```

There must be no normal application path that leaves:

```text
Charge persisted
JournalEntry absent
posted_at nil
```

---

# 15. Create `Charges::PostService`

Create:

```text
app/services/charges/post_service.rb
```

This service translates `Charge` semantics into accounting primitives.

It should accept only a persisted, live, unvoided `Charge`.

For rent:

```ruby
[
  Accounting::PostingSpec.new(
    account_key: "tenant_receivable",
    amount_cents: charge.amount_cents,
    tenancy: charge.tenancy
  ),
  Accounting::PostingSpec.new(
    account_key: "rental_income",
    amount_cents: -charge.amount_cents,
    tenancy: charge.tenancy
  )
]
```

For late fee:

```text
tenant_receivable
late_fee_income
```

For reimbursement:

```text
tenant_receivable
reimbursement_income
```

---

# 16. Add an account for `other` charges

The Milestone 2 system chart does not currently have a semantically-correct destination for `Charge(kind: other)`.

Add:

```text
other_tenant_income
```

with:

```text
name: Other Tenant Income
account_type: income
```

to `Accounting::ChartOfAccounts`.

`Charge(kind: other)` posts:

```text
Dr Tenant Receivable
Cr Other Tenant Income
```

Do not overload `reimbursement_income` or `rental_income`.

Update chart-provisioning tests.

`ensure_for(user)` must continue to add missing accounts idempotently.

---

# 17. Charge journal-entry identity

Use:

```text
source: charge
event_type: "charge_posted"
occurred_on: charge.charge_date
```

Description should be deterministic.

For example:

```text
Rent - August 2026
Late fee
Utility reimbursement
```

Do not include timestamps or other nondeterministic text because `PostEntryService` treats description differences as idempotency conflicts.

---

# 18. Create `Charges::CreateService`

Create a single low-level domain creation service:

```text
Charges::CreateService
```

Inputs should be domain-oriented:

```text
tenancy
charge_kind
amount_cents
charge_date
due_on
description

rent_term           optional
source_expense      optional
service_period_start optional
service_period_end   optional
```

Inside one outer transaction:

1. lock any domain objects required by the specialized caller;
2. create the `Charge`;
3. invoke `Charges::PostService`;
4. fail the transaction if posting fails;
5. set `charge.posted_at` to the journal entry's `posted_at`;
6. commit both the charge and journal entry atomically.

Return:

```text
ServiceResult.success(
  charge: charge,
  journal_entry: journal_entry
)
```

Expected domain failures return structured failures.

Unexpected accounting-invariant violations should fail loudly.

---

# 19. Do not call `Accounting::PostEntryService` from controllers

The call graph should be:

```text
Controller / Job / Domain Service
          │
          ▼
Charges::* domain service
          │
          ▼
Charges::PostService
          │
          ▼
Accounting::PostEntryService
```

Never:

```text
ChargesController
  -> Accounting::PostEntryService
```

The accounting layer must not know how a user intent such as "charge late fee" is selected.

---

# 20. Implement manual fee creation

Create:

```text
Charges::CreateFeeService
```

Supported manual kinds:

```text
late_fee
other
```

Inputs:

```text
tenancy
kind
amount_cents
charge_date
due_on
description
```

Validate the tenancy belongs to the authenticated user at the controller boundary.

Default:

```text
charge_date = Date.current
due_on = charge_date
```

unless explicitly supplied.

Do **not** automatically assess late fees from `late_period_days` in this milestone.

Running-account semantics without charge allocation make automatic fee qualification a separate business-rule problem.

---

# 21. Implement reimbursement charge creation

Create:

```text
Charges::CreateReimbursementService
```

Inputs:

```text
expense
tenancy
amount_cents
charge_date
due_on
description
```

The service must validate:

```text
expense.property == tenancy.property
expense.accounting_user == tenancy.accounting_user
```

Then call `Charges::CreateService` with:

```text
charge_kind: reimbursement
source_expense: expense
```

Do not post the `Expense` itself yet.

That belongs to Milestone 5.

This milestone posts only the tenant receivable/income side of reimbursement.

---

# 22. Change Expense from one reimbursement to many

The current model has:

```ruby
has_one :tenant_charge
```

and its reimbursement helper assumes one charge.

Replace that with:

```ruby
has_many :reimbursement_charges,
  -> { where(charge_kind: "reimbursement") },
  class_name: "Charge",
  foreign_key: :source_expense_id,
  dependent: :restrict_with_error
```

This implements the architecture rule:

```text
one expense
may produce
zero, one, or multiple reimbursement charges
```

Do not introduce a uniqueness constraint on `source_expense_id`.

---

# 23. Replace `Expenses::TenantChargeService`

Delete:

```text
Expenses::TenantChargeService
```

The existing implementation updates/destroys one `TenantCharge` as the Expense form changes.

That behavior is incompatible with immutable posted charges.

Replace the flow with an explicit create operation.

For a newly-created expense whose current form requests a reimbursement:

```text
save Expense
create reimbursement Charge
```

inside one transaction.

If reimbursement charge creation fails, roll back creation of the new Expense.

---

# 24. Do not mutate reimbursement charges when Expense is edited

Once created and posted, reimbursement charges are historical financial events.

Editing:

```text
expense amount
category
description
```

must **not** silently change or destroy an already-posted reimbursement charge.

For this milestone:

```text
Expense edit != reimbursement charge edit
```

If an existing reimbursement is wrong:

```text
void reimbursement charge
create replacement
```

The full Expense model/lifecycle will be redesigned in Milestone 5.

Do not prematurely make Expense itself immutable/accounting-backed here.

---

# 25. Expense form compatibility

The current Expense form can retain its existing "tenant reimbursable" convenience for **new expenses**.

During creation:

```text
Expense form
  amount: $300
  tenant reimbursable: yes
  tenancy: Unit A
  reimburse amount: $150
```

may create:

```text
Expense $300

Charge:
  reimbursement
  $150
  tenancy Unit A
  source_expense Expense
```

On edit, existing reimbursement charges should be displayed as separate immutable linked records rather than represented as mutable virtual fields.

Avoid preserving the old fiction that an Expense owns one mutable TenantCharge.

---

# 26. Rent-generation service

Create:

```text
RentCharges::GenerateService
```

Suggested API:

```ruby
RentCharges::GenerateService.call(
  tenancy:,
  service_month:
)
```

Normalize:

```text
service_month -> beginning_of_month
```

This service generates at most one live rent charge for that tenancy/calendar month.

---

# 27. Monthly rent semantics

Milestone 3 supports:

```text
frequency: monthly
```

only.

Do not implement rent proration.

For this milestone:

```text
a partial first or final month uses the full monthly RentTerm amount
```

Document this explicitly.

Proration can later become its own feature rather than being silently approximated.

---

# 28. Prevent ambiguous mid-month rent changes

A full-month rent model cannot correctly interpret arbitrary mid-month rent-term transitions without defining proration.

Therefore modify:

```text
RentTerms::ChangeService
```

so changes to an established monthly tenancy must take effect on the first day of a calendar month:

```text
effective_from == effective_from.beginning_of_month
```

The initial RentTerm created with a tenancy may still begin on the actual tenancy commencement date.

Example allowed:

```text
Tenancy begins:
January 15

Initial RentTerm:
January 15 onward
```

Example rejected:

```text
Existing tenancy
rent change effective July 17
```

Require:

```text
July 1
```

instead.

Add a clear validation error explaining that rent proration is not supported.

---

# 29. Selecting the RentTerm for a month

For each service month:

```text
month_start
month_end
```

Determine the applicable date as:

```text
max(
  month_start,
  tenancy.commencement_date
)
```

Find the `RentTerm` active on that date.

Because subsequent changes are required to start on the first day of a month, there can be only one applicable term for the month after the initial partial month.

If there is no RentTerm active at that date:

```text
no rent charge
```

This preserves intentional RentTerm gaps.

Do not fall back to `most_recent_rent_term`.

---

# 30. Rent service-period calculation

For a generated rent charge:

```text
service_period_start =
  max(
    month_start,
    tenancy.commencement_date,
    rent_term.effective_from
  )
```

and:

```text
service_period_end =
  min(
    month_end,
    tenancy.termination_date || month_end,
    rent_term.effective_until || month_end
  )
```

If:

```text
service_period_end < service_period_start
```

the month is not applicable.

---

# 31. Rent due date

Use the existing:

```ruby
rent_term.due_date_for(year, month)
```

which already clamps day 29/30/31 to the month's final calendar day.

For an initial partial month, prevent the charge from becoming due before the tenancy/rent term existed:

```text
due_on =
  max(
    rent_term.due_date_for(year, month),
    service_period_start
  )
```

Example:

```text
Tenancy starts January 15
due_day = 1

January rent:
  service period starts Jan 15
  due_on = Jan 15
```

---

# 32. Rent accounting date

For rent charges use:

```text
charge_date = due_on
```

and therefore:

```text
JournalEntry.occurred_on = due_on
```

This preserves the existing behavioral idea that rent begins affecting the outstanding balance on its due date rather than at the beginning of a service period.

The service period remains separate metadata explaining what month the rent is for.

---

# 33. Rent amount

For Milestone 3:

```text
charge.amount_cents = rent_term.amount_cents
```

No daily calculation.

No month-length calculation.

No proration.

---

# 34. Rent generation locking

Follow the Milestone 1 lock ordering.

Inside generation:

```text
lock Tenancy
lock relevant RentTerm rows
check existing Charge
create/post Charge
```

Do not introduce a lock order that conflicts with `RentTerms::ChangeService`.

The partial unique index remains the final protection against duplicate concurrent generation.

Handle a uniqueness race as:

```text
reload existing live rent charge
return it idempotently if equivalent
```

If the existing charge has a different expected amount/term for the same service period:

```text
return conflict
```

Do not silently accept contradictory rent history.

---

# 35. Rent generation must be idempotent

Repeated calls:

```ruby
GenerateService.call(
  tenancy: tenancy,
  service_month: Date.new(2026, 8, 1)
)
```

must produce:

```text
one Charge
one JournalEntry
two Postings
```

not duplicates.

Idempotency must hold:

- sequentially
- after retry
- under concurrent execution

---

# 36. Generate-through service

Create:

```text
RentCharges::GenerateThroughService
```

Suggested API:

```ruby
RentCharges::GenerateThroughService.call(
  tenancy:,
  through: Date.current
)
```

Iterate calendar months from:

```text
tenancy.commencement_date.beginning_of_month
```

through:

```text
through.beginning_of_month
```

For each month:

1. resolve the applicable term;
2. calculate the due date;
3. skip it if:
   ```text
   due_on > through
   ```
4. call `RentCharges::GenerateService`.

This service is the catch-up mechanism.

---

# 37. Do not create future receivables yet

`GenerateThroughService` should generate only charges whose:

```text
due_on <= through
```

Do not create December rent in November merely because the December RentTerm is known.

This keeps:

```text
current Tenant Receivable
```

aligned with obligations that have actually reached their charge date.

Future accrual/prebilling can be added deliberately later if wanted.

---

# 38. Automatic rent generation job

Create:

```text
GenerateDueRentChargesJob
```

The job should:

1. identify tenancies that have commenced by `Date.current`;
2. call `RentCharges::GenerateThroughService` through `Date.current`;
3. rely on the generator's idempotency;
4. continue processing other tenancies if one tenancy has an expected domain validation problem;
5. surface unexpected accounting failures.

Use `find_each` rather than loading all tenancies.

---

# 39. Schedule rent generation

Add the new job to:

```text
config/recurring.yml
```

The repository already uses Solid Queue recurring configuration in production.

Run the rent-generation job daily.

The exact wall-clock time is not financially meaningful because accounting uses:

```text
Charge.charge_date
JournalEntry.occurred_on
```

rather than job execution time.

Use `Date.current` consistently.

---

# 40. Generate rent when a tenancy is created

At the end of successful:

```text
Tenancies::CreateService
```

after the initial `RentTerm` exists, generate all rent charges due through:

```text
Date.current
```

if the tenancy commenced in the past or today.

This provides immediate correct balance for:

```text
historical tenancy entered today
```

without waiting for the recurring job.

Keep the entire aggregate creation transactional where practical.

If rent posting fails due to a programming/accounting invariant, do not silently create a tenancy whose initial financial state is incomplete.

---

# 41. Generate newly-due rent after rent changes

After:

```text
RentTerms::ChangeService
```

successfully creates the new term, call:

```text
RentCharges::GenerateThroughService
```

through `Date.current`.

This matters when a user enters a rent change whose effective date is already in the past but whose affected service periods do not yet have charges.

---

# 42. Protect posted rent history from retroactive RentTerm edits

The PRD explicitly says posted historical rent charges are never modified when rent terms change.

Therefore `RentTerms::ChangeService` must reject a change whose new effective date would alter a service period already represented by a live posted rent charge.

Example:

```text
July rent already posted at $2,000

Attempt:
new RentTerm effective July 1
$2,100
```

Reject with an error such as:

```text
July rent has already been charged.
Void the affected rent charge before changing the rent term.
```

Do not rewrite the July Charge.

---

# 43. Protect tenancy termination against posted rent

Update:

```text
Tenancies::UpdateService
```

so shortening a tenancy cannot place an existing live rent charge outside the new tenancy bounds.

Example:

```text
August rent charge:
service_period_end = Aug 31

Attempt:
terminate tenancy Aug 15
```

Reject until the affected rent charge is voided or otherwise corrected.

This is the financial counterpart to the existing effective-date child protections.

---

# 44. Implement charge voiding

Create:

```text
Charges::VoidService
```

Suggested input:

```text
charge
occurred_on
reason optional
```

Within one transaction:

1. lock the Charge;
2. if already voided:
   - return the existing reversal idempotently when inputs match;
3. find the charge's `charge_posted` journal entry;
4. call `Accounting::ReverseEntryService`;
5. set:
   ```text
   charge.voided_at = Time.current
   ```
6. commit.

Do not delete the Charge.

---

# 45. Void accounting semantics

Example:

Original late fee:

```text
Dr Tenant Receivable   +5000
Cr Late Fee Income     -5000
```

Void:

```text
Dr Late Fee Income     +5000
Cr Tenant Receivable   -5000
```

The tenancy balance therefore automatically reflects the void because both entries are present in the subledger.

No special `WHERE voided_at IS NULL` belongs in the accounting balance query.

The ledger, not Charge status, determines net balance.

---

# 46. Charge routes

Replace the old resources with something like:

```ruby
resources :tenancies do
  resources :charges, only: %i[new create]
end

resources :charges, only: %i[show] do
  member do
    post :void
  end
end
```

Do not expose:

```text
edit
update
destroy
```

for posted charges.

Delete the old:

```text
tenant_charges
scheduled_rents
```

routes.

The current application still exposes read-only `scheduled_rents` and destroyable `tenant_charges`.

---

# 47. ChargesController

Create:

```text
ChargesController
```

Every charge lookup must be user-scoped.

For example:

```ruby
authenticated_user.charges.find(...)
```

or through a tenancy verified to belong to the user.

`create` should resolve:

```text
tenancy
charge kind
```

and delegate to the appropriate domain service.

Controller code must not determine account keys.

---

# 48. Charge UI

On the tenancy page provide:

```text
[Add Charge]
```

Manual charge kinds:

```text
Late fee
Other
```

Reimbursement charges should normally originate from an Expense workflow, not from a generic free-form reimbursement form.

Display a tenancy's recent charges with:

```text
date
kind
description
amount
due date
voided status
```

A voided charge remains visible.

Do not display it as deleted.

---

# 49. Remove `ScheduledRent`

Delete:

```text
app/models/scheduled_rent.rb
ScheduledRentsController
scheduled_rents views
scheduled_rents routes
scheduled_rents specs
scheduled_rents signatures
```

Drop:

```text
scheduled_rents
```

from the schema.

Remove all associations to it.

The current model also contains `covered?` and `late?` calculations based on the old cumulative balance query.

Do not port those methods mechanically to `Charge`.

Per-charge paid status is intentionally undefined without allocation.

---

# 50. Remove `TenantCharge`

Delete:

```text
app/models/tenant_charge.rb
TenantChargesController
tenant_charges views
tenant_charges routes
tenant_charges specs
tenant_charges signatures
```

Drop:

```text
tenant_charges
```

from the schema.

The current `TenantCharge` requires an Expense.

`Charge` removes that incorrect constraint:

```text
late fee -> no Expense
other    -> no Expense
reimbursement -> Expense
```

---

# 51. Update associations

## Tenancy

Replace:

```ruby
has_many :scheduled_rents
has_many :tenant_charges
```

with:

```ruby
has_many :charges, dependent: :restrict_with_error
```

Update:

```ruby
financial_history?
```

to include:

```text
charges
tenant_payments
accounting_postings
```

## Property

Expose charges through its tenancies as appropriate.

## User

Expose charges through owned tenancies if useful for authorization/querying.

## RentTerm

Add:

```ruby
has_many :rent_charges,
  -> { where(charge_kind: "rent") },
  class_name: "Charge",
  dependent: :restrict_with_error
```

## Expense

Use the reimbursement-charge association described above.

---

# 52. Implement `Accounting::TenancyBalanceQuery`

Create:

```text
app/queries/accounting/tenancy_balance_query.rb
```

Resolve the user's:

```text
tenant_receivable
```

account.

The canonical calculation is:

```text
SUM(postings.amount_cents)
```

where:

```text
postings.account_id = tenant_receivable.id
postings.tenancy_id = tenancy.id
journal_entries.occurred_on <= requested_date
```

Join through `JournalEntry` for the accounting date.

Do not filter by:

```text
source_type
event_type
charge_kind
voided_at
```

Any legitimate event affecting Tenant Receivable belongs in the balance.

That is precisely why the ledger exists.

---

# 53. Balance as-of behavior

Implement:

```ruby
balance_cents_as_of(date)
current_balance_cents
```

Examples:

```text
Rent charge, Aug 1       +200000
Payment, Aug 5            -50000

Aug 3 balance             +200000
Aug 5 balance             +150000
```

Future-dated postings must not affect an earlier balance.

Reversal entries affect the balance on their own `occurred_on`, not retroactively on the original charge date.

---

# 54. Replace Tenancy balance delegation

Delete:

```text
Tenancies::BalanceQuery
```

and its RBS/specs once replacements exist.

Update `Tenancy` to delegate to:

```text
Accounting::TenancyBalanceQuery
```

Remove obsolete methods if no callers remain:

```text
total_debits
total_credits
```

Do not retain compatibility methods solely for deleted `ScheduledRent#covered?`.

---

# 55. Update balance presentation

The tenancy page currently treats positive balance as credit.

Update it to:

```text
balance > 0
  red / outstanding
  "Tenancy owes $X"

balance == 0
  neutral/success
  "Account settled"

balance < 0
  green / credit
  "Account credit $X"
```

Do not negate the query result in the view.

Make the UI use the same sign convention as the accounting subledger.

---

# 56. Update payment form prefill

The current `TenantPaymentsController#new` assumes:

```text
negative balance = amount owed
```

and takes its absolute value.

Change it to the new convention:

```ruby
owed = tenancy.current_balance

tenant_payment.amount =
  owed.positive? ? owed : BigDecimal("0")
```

After:

```text
$2,000 outstanding
```

the payment form should default to:

```text
$2,000
```

After a tenant has credit:

```text
$0
```

---

# 57. Temporary legacy TenantPayment posting service

Create:

```text
TenantPayments::PostLegacyService
```

or equivalently named, with an explicit comment that Milestone 4 removes it.

For a persisted `TenantPayment`:

```text
Dr Cash               +amount
Cr Tenant Receivable  -amount
```

Both postings use:

```text
tenancy
```

as their dimensional source.

There is no Party dimension because the legacy model does not preserve payer identity.

---

# 58. Legacy payment amount conversion

Do not pass decimal dollars through floating point.

Convert:

```text
TenantPayment.amount
```

to integer cents using `BigDecimal`.

Reject a payment that cannot round-trip exactly to cents.

Example:

```text
2000.00 -> 200000
```

Do not use:

```ruby
(payment.amount.to_f * 100).to_i
```

---

# 59. Legacy payment journal identity

Use:

```text
source: tenant_payment
event_type: "legacy_tenant_payment_posted"
occurred_on: tenant_payment.payment_date
```

Description must be deterministic.

Example:

```text
Tenant payment
```

Do not include generated timestamps.

---

# 60. Temporary `TenantPayments::CreateService`

The current controller saves `TenantPayment` directly.

Replace direct creation with:

```text
TenantPayments::CreateService
```

Inside one transaction:

1. save the `TenantPayment`;
2. invoke the temporary posting adapter;
3. roll back the payment if posting fails;
4. return both payment and journal entry.

This mirrors the new Charge creation invariant:

```text
financial source + accounting effect commit together
```

---

# 61. Adapt every payment creation path

Search again after introducing the service:

```bash
rg -n \
  'TenantPayment\.(new|create|create!)|tenant_payments\.(build|create|create!)' \
  app db
```

Any path that ultimately persists a payment must use the transactional creation/posting boundary.

In particular inspect:

```text
manual payment UI
payment ingestion confirmation
seeds
test setup that represents application behavior
```

Do not allow ingestion-confirmed payments to bypass the ledger.

---

# 62. Freeze legacy TenantPayment mutation for one milestone

Once `TenantPayment` affects Tenant Receivable, its current generic edit/update/delete behavior is unsafe.

Do not implement a half-correct mutable ledger synchronization mechanism.

For Milestone 3 remove normal:

```text
edit
update
destroy
```

payment routes/actions.

Keep:

```text
index
show
new
create
PDF receipt
```

If correction is needed, Milestone 4 introduces proper immutable `Receipt` correction/reversal semantics.

This temporary limitation is safer than allowing a payment amount to change while its journal entry remains immutable.

---

# 63. Do not add payment reversal UX in Milestone 3

The accounting engine already knows how to reverse entries.

Do not expose a generic:

```text
void TenantPayment
```

workflow just to bridge one milestone unless implementation needs it for a critical existing flow.

Milestone 4 owns:

```text
Receipt correction
Receipt voiding
replacement
payer identity
```

Keep the transitional adapter as small as possible.

---

# 64. Update seeds

Replace seeded:

```text
ScheduledRent
TenantCharge
```

records with:

```text
Charge
```

through actual domain services.

Seed rent charges through:

```text
RentCharges::GenerateThroughService
```

where possible rather than manually creating them.

Seed legacy payments through:

```text
TenantPayments::CreateService
```

so the development database satisfies the same ledger invariants as the application.

Do not manually create balancing journal entries in `seeds.rb`.

---

# 65. Update the interim property financial-items query

The full property ledger does not become accounting-backed until a later milestone.

For now update:

```text
Properties::FinancialItemsQuery
```

from:

```text
ScheduledRent
TenantPayment
TenantCharge
Expense
```

to:

```text
Charge
TenantPayment
Expense
```

The current query explicitly unions the first four legacy record types.

Use:

```text
Charge.charge_date
```

for the interim presentation date.

Exclude or visibly mark voided charges rather than presenting them as normal active charges.

Do not claim this query is the authoritative accounting ledger.

That cutover belongs to the reporting milestone.

---

# 66. Do not double count payments in balance

Once the temporary payment adapter is live:

```text
TenantPayment table
```

must no longer participate directly in tenancy-balance calculation.

The only balance source is:

```text
Posting
  account = tenant_receivable
```

Otherwise every payment would be counted twice.

Add a regression test specifically proving this.

---

# 67. Charge model test matrix

Test:

- Charge requires tenancy.
- Charge requires valid kind.
- Charge requires positive cents.
- Charge requires charge date.
- Charge requires due date.
- `accounting_user` follows tenancy.
- Rent requires RentTerm.
- Rent requires service period.
- RentTerm must belong to same tenancy.
- Reimbursement requires Expense.
- Reimbursement Expense must belong to same property/user.
- Late fee does not require Expense.
- Other does not require Expense.
- Service-period end cannot precede start.
- Posted financial fields cannot mutate.
- Lifecycle void metadata may be set through the service.
- Charge with accounting history cannot be destroyed normally.

---

# 68. Charge posting test matrix

For `$2,000` rent:

```text
Tenant Receivable  +200000
Rental Income      -200000
```

For `$50` late fee:

```text
Tenant Receivable   +5000
Late Fee Income     -5000
```

For `$300` reimbursement:

```text
Tenant Receivable  +30000
Reimbursement      -30000
```

For `$25` other:

```text
Tenant Receivable     +2500
Other Tenant Income   -2500
```

Verify on every posting:

```text
property_id
rentable_unit_id
tenancy_id
```

match the Charge tenancy.

---

# 69. Charge creation atomicity tests

Force accounting posting failure after source creation would otherwise succeed.

Assert:

```text
Charge.count unchanged
JournalEntry.count unchanged
Posting.count unchanged
```

Also force Charge validation failure.

Assert:

```text
no accounting records created
```

---

# 70. Rent-generation test matrix

Test at least:

## Normal month

```text
RentTerm:
$2,000
due day 1

August:
charge $2,000
due Aug 1
service Aug 1..Aug 31
```

## Month-end clamp

```text
due day 31
February 2027

due Feb 28
```

## Partial first month

```text
tenancy begins Jan 15
due day 1

service Jan 15..Jan 31
due Jan 15
full monthly amount
```

## Partial final month

Full monthly amount under the explicit no-proration rule.

## Rent change

```text
Jan-Jun: $2,000
Jul onward: $2,150
```

June and July charges use the correct terms.

## Intentional gap

No RentTerm active for July:

```text
no July rent Charge
```

## Future due date

Through Aug 10 with due day 15:

```text
no August Charge yet
```

Through Aug 15:

```text
one August Charge
```

## Idempotency

Repeated generation creates one Charge.

## Concurrency

Concurrent generation creates one live Charge.

## Different tenancies

Same month generates independent charges.

---

# 71. Retroactive rent-change tests

Given a posted July rent charge:

```text
change RentTerm effective July 1
```

must fail.

Given posted charges through June:

```text
change RentTerm effective July 1
```

may succeed.

Given a voided July charge:

```text
change effective July 1
regenerate July
```

may succeed and produces a new Charge source and journal entry.

---

# 72. Charge void tests

Verify:

- void creates reversal;
- original Charge remains;
- original JournalEntry remains;
- original postings remain;
- reversal amounts are exact negatives;
- charge receives `voided_at`;
- tenancy balance changes automatically;
- second identical void is idempotent;
- conflicting reversal date follows Milestone 2 idempotency rules;
- a voided rent charge frees its live rent-generation uniqueness key.

---

# 73. Reimbursement tests

Test:

```text
Expense: Property A

Tenancy: Property A
=> reimbursement allowed
```

Test:

```text
Expense: Property A

Tenancy: Property B
=> rejected
```

Test one Expense producing:

```text
Charge A -> Unit 1
Charge B -> Unit 2
```

without changing or deleting either.

This proves the old one-expense/one-charge assumption is gone.

---

# 74. Temporary TenantPayment posting tests

Test:

```text
Payment $500

Cash               +50000
Tenant Receivable  -50000
```

Test:

- source is TenantPayment;
- event type is transitional legacy-payment event;
- dimensions are correct;
- repeated posting is idempotent;
- cross-user payment fails;
- payment creation rolls back when ledger posting fails.

---

# 75. Ledger-backed balance test matrix

This is the primary Milestone 3 acceptance suite.

## Rent only

```text
Rent charge        +$2,000

balance owed        $2,000
```

## Partial payment

```text
Rent charge        +$2,000
Payment              -$500

balance owed        $1,500
```

## Fee

```text
Previous balance    $1,500
Late fee              $100

balance owed        $1,600
```

## Second payment

```text
Previous balance    $1,600
Payment            -$2,000

account credit        $400
```

This is the PRD's Milestone 3 sequence expressed with the new sign convention.

---

# 76. Balance isolation tests

Test:

- Unit A postings do not affect Unit B.
- Another user's postings do not affect this tenancy.
- Rental Income postings do not affect balance directly.
- Cash postings do not affect balance directly.
- Only `tenant_receivable` postings with matching tenancy count.
- A tenant receivable posting with a different tenancy does not count.
- A reversal counts automatically.
- Future accounting dates do not count in earlier `as_of` queries.

---

# 77. Running-account semantics test

Explicitly prove there is no allocation requirement.

Example:

```text
Jan rent       +2000
Feb rent       +2000
payment        -3000
```

Balance:

```text
+1000 owed
```

No payment-to-January or payment-to-February association is required.

Do not introduce charge settlement rows.

---

# 78. Controller/request scenarios

Add end-to-end/request coverage for:

## Manual late fee

1. Open tenancy.
2. Add `$50` late fee.
3. Charge appears.
4. Balance increases `$50`.

## Other charge

1. Add other charge.
2. Balance increases.
3. Correct income account is used.

## Reimbursement

1. Create expense.
2. Request tenant reimbursement.
3. Reimbursement Charge appears.
4. Balance increases.
5. Expense remains an independent record.

## Rent generation

1. Create tenancy with rent due today.
2. Rent Charge exists.
3. Balance reflects rent.

## Payment

1. Record payment.
2. TenantPayment is created.
3. Ledger receives payment posting.
4. Balance decreases.

## Void charge

1. Void fee.
2. Charge remains visible as voided.
3. Balance returns to prior value.

---

# 79. Recurring job tests

Test the job:

- catches up missed due months;
- does not duplicate charges;
- skips future due dates;
- skips months with RentTerm gaps;
- handles terminated tenancies correctly;
- does not stop processing all tenancies because one expected validation fails;
- surfaces unexpected accounting failures.

No test should depend on actual wall-clock month boundaries; use time travel.

---

# 80. Update factories

Add:

```text
:charge
```

with traits:

```text
:rent_charge
:late_fee_charge
:reimbursement_charge
:other_charge
:voided_charge
```

Prefer domain services when a test needs a **real posted financial event**.

Direct factory construction is appropriate for isolated model-validation tests.

Avoid creating a Charge directly in a balance spec without its accounting entry.

---

# 81. Update RBS

Add/update signatures for:

```text
Charge

Charges::CreateService
Charges::PostService
Charges::CreateFeeService
Charges::CreateReimbursementService
Charges::VoidService

RentCharges::GenerateService
RentCharges::GenerateThroughService
GenerateDueRentChargesJob

Accounting::TenancyBalanceQuery

TenantPayments::CreateService
TenantPayments::PostLegacyService
```

Update existing signatures for:

```text
Tenancy
RentTerm
Expense
Property
User
```

Remove signatures for:

```text
ScheduledRent
TenantCharge
Tenancies::BalanceQuery
Expenses::TenantChargeService
```

Regenerate Rails signatures after schema changes:

```bash
bin/rails rbs_rails:all
bundle exec rbs validate
bundle exec steep check
```

Keep the broad Steep coverage restored during Milestone 2.

---

# 82. Documentation

Add:

```text
documentation/double_entry_accounting/implementation_plan_milestone_3.md
```

and update accounting architecture documentation to explain:

- `Charge` is a semantic receivable event;
- posted Charge records are immutable;
- charge kinds map to income accounts;
- Tenant Receivable is the tenancy subledger;
- balance sign convention;
- rent service periods versus charge/accounting dates;
- no-proration policy;
- rent generation idempotency;
- charge void/reversal behavior;
- reimbursement Expense and Charge are separate events;
- legacy `TenantPayment` posting is temporary;
- Milestone 4 removes the legacy payment bridge.

---

# 83. Search for stale legacy charge code

Before finalizing:

```bash
rg -n \
  'ScheduledRent|scheduled_rent|scheduled_rents|TenantCharge|tenant_charge|tenant_charges|Tenancies::BalanceQuery|Expenses::TenantChargeService' \
  app config db spec sig
```

Expected result:

```text
no live application-code references
```

Documentation describing historical migration may remain.

---

# 84. Verify direct accounting creation remains contained

Run:

```bash
rg -n \
  'Posting\.(create|create!|new)|postings\.(create|create!|build)|JournalEntry\.(create|create!|new)' \
  app
```

Production persistence should remain restricted to the accounting services established in Milestone 2.

Charge services should use:

```text
Accounting::PostingSpec
Accounting::PostEntryService
Accounting::ReverseEntryService
```

rather than direct record construction.

---

# 85. Verify all Charge creation is service-owned

Run:

```bash
rg -n \
  'Charge\.(create|create!|new)|charges\.(create|create!|build)' \
  app
```

Review every production hit.

A controller should not bypass:

```text
Charges::CreateService
```

because a directly-persisted Charge would have no ledger entry.

---

# 86. Verify every payment creation path posts

Run the payment persistence search again.

There must be no production path that creates a new `TenantPayment` without invoking the temporary ledger posting boundary.

This is mandatory because balance no longer reads `tenant_payments` directly.

---

# 87. Clean database verification

Because there is still no production data to preserve, test from a clean database:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate
```

Verify these tables are gone:

```text
scheduled_rents
tenant_charges
```

Verify:

```text
charges
```

exists with its constraints/indexes.

---

# 88. Manual smoke test

Run:

```bash
bin/dev
```

Using a clean database:

1. Create a property.
2. Create a tenancy with rent due today.
3. Confirm a rent Charge was generated.
4. Confirm balance is amount owed.
5. Record a partial payment.
6. Confirm balance decreases.
7. Add a late fee.
8. Confirm balance increases.
9. Void the late fee.
10. Confirm balance returns.
11. Create an Expense with reimbursement.
12. Confirm reimbursement Charge appears.
13. Confirm Expense remains independent.
14. Change rent effective next month.
15. Time-travel/test or manually generate the next due month.
16. Confirm new rent amount is used.
17. Verify old rent Charge was never modified.
18. Open property financial history.
19. Verify old ScheduledRent/TenantCharge concepts are absent.
20. Exercise payment ingestion and confirm its generated legacy payment affects the ledger exactly once.

---

# 89. Final quality gate

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

Do not rely only on accounting-focused specs.

---

# 90. Suggested commit boundaries

## Commit 1: Add Charge domain and schema

Include:

```text
charges table
Charge model
associations
validations
immutability
factories
model specs
```

## Commit 2: Add Charge accounting

Include:

```text
Charges::PostService
Charges::CreateService
fee service
reimbursement service
other tenant income account
posting specs
atomicity specs
```

## Commit 3: Replace reimbursement TenantCharge

Include:

```text
Expense has-many reimbursement charges
Expenses::TenantChargeService removal
expense create flow adaptation
TenantCharge deletion
controller/routes/views/spec cleanup
```

## Commit 4: Add rent-charge generation

Include:

```text
RentCharges::GenerateService
GenerateThroughService
rent change constraints
retroactive charge guards
recurring job
recurring schedule
concurrency/idempotency specs
ScheduledRent deletion
```

## Commit 5: Move payments into Tenant Receivable temporarily

Include:

```text
TenantPayments::CreateService
PostLegacyService
manual payment flow
ingestion flow
temporary mutation restrictions
payment posting specs
```

## Commit 6: Cut tenancy balance over to ledger

Include:

```text
Accounting::TenancyBalanceQuery
Tenancy delegation
UI sign changes
payment prefill changes
running-account tests
legacy BalanceQuery deletion
```

## Commit 7: Cleanup, typing, docs

Include:

```text
financial-items adaptation
RBS
Steep
generated Rails signatures
docs
stale-reference cleanup
full quality gate
```

Each commit should preferably remain green.

---

# 91. Milestone acceptance checklist

## Charge domain

- [ ] `Charge` exists.
- [ ] Charge money uses integer cents.
- [ ] Rent charges require RentTerm and service period.
- [ ] Late fees do not require Expense.
- [ ] Reimbursements require Expense.
- [ ] Other charges use their own income account.
- [ ] Posted Charges cannot be financially edited.
- [ ] Charges are never hard-deleted after posting.
- [ ] Voids use journal reversals.

## Accounting

- [ ] Rent posts to Tenant Receivable / Rental Income.
- [ ] Late fee posts to Tenant Receivable / Late Fee Income.
- [ ] Reimbursement posts to Tenant Receivable / Reimbursement Income.
- [ ] Other charge posts to Tenant Receivable / Other Tenant Income.
- [ ] Every Charge posting balances.
- [ ] Every Charge posting carries tenancy/unit/property dimensions.
- [ ] Charge and JournalEntry creation are atomic.
- [ ] Charge posting is idempotent.

## Rent generation

- [ ] One live rent Charge per tenancy/service month.
- [ ] Duplicate generation is impossible under concurrency.
- [ ] Correct RentTerm is selected.
- [ ] Rent gaps generate no charge.
- [ ] Month-end due dates clamp correctly.
- [ ] Initial partial month works.
- [ ] No proration occurs.
- [ ] Future-due rent is not generated early.
- [ ] Daily recurring generation exists.
- [ ] Historical/catch-up generation exists.
- [ ] Posted rent history blocks conflicting retroactive rent-term changes.

## Reimbursements

- [ ] `TenantCharge` no longer exists.
- [ ] Expense supports many reimbursement Charges.
- [ ] One Expense can reimburse multiple tenancies.
- [ ] Cross-property reimbursement is rejected.
- [ ] Editing Expense does not rewrite posted reimbursement history.

## Scheduled rent

- [ ] `ScheduledRent` no longer exists.
- [ ] `scheduled_rents` table is gone.
- [ ] Scheduled-rent routes/controllers/views are gone.
- [ ] `covered?`/`late?` legacy logic is not copied onto Charge.

## Tenant receivable

- [ ] `Accounting::TenancyBalanceQuery` exists.
- [ ] `Tenancies::BalanceQuery` is gone.
- [ ] Balance comes exclusively from Tenant Receivable postings.
- [ ] Positive balance means owed.
- [ ] Negative balance means tenant credit.
- [ ] As-of dates use JournalEntry accounting dates.
- [ ] Reversals automatically affect balance.
- [ ] Other accounts do not affect tenancy balance.

## Temporary payment bridge

- [ ] Newly-created TenantPayments post Dr Cash / Cr Tenant Receivable.
- [ ] Manual payment creation uses the bridge.
- [ ] Payment ingestion uses the bridge.
- [ ] Seeds use the bridge.
- [ ] No payment is counted directly from `tenant_payments` in balance.
- [ ] Legacy TenantPayment update/delete is disabled while posted.
- [ ] No `Receipt` model has been pulled into this milestone.
- [ ] Temporary bridge is explicitly documented for removal in Milestone 4.

## UI

- [ ] Tenancy balance displays new sign semantics correctly.
- [ ] Payment prefill uses amount owed correctly.
- [ ] User can add late fee/other Charge.
- [ ] User can view Charges.
- [ ] User can void Charge.
- [ ] Voided Charge remains visible.
- [ ] Expense reimbursement flow creates Charge.
- [ ] No ScheduledRent/TenantCharge terminology remains in normal UI.

## Quality

- [ ] RBS validates.
- [ ] Steep passes with broad application coverage.
- [ ] RuboCop passes.
- [ ] RSpec passes.
- [ ] Coverage remains above CI threshold.
- [ ] Security scans pass.
- [ ] Concurrency tests cover rent-generation uniqueness.
- [ ] Accounting invariants remain green.

---

# 92. Desired end state

After Milestone 3:

```text
Tenancy
│
├── RentTerm
│
├── Charge
│   ├── rent
│   ├── late_fee
│   ├── reimbursement
│   └── other
│
└── TenantPayment       # temporary; replaced in M4
```

Financial effects:

```text
Rent charge
  Dr Tenant Receivable
  Cr Rental Income

Late fee
  Dr Tenant Receivable
  Cr Late Fee Income

Reimbursement
  Dr Tenant Receivable
  Cr Reimbursement Income

Legacy payment
  Dr Cash
  Cr Tenant Receivable
```

And the balance becomes simply:

```text
Tenant Receivable postings for tenancy
```

So the sequence:

```text
Rent               +$2,000
Payment              -$500
Late fee              +$100
Payment            -$2,000
                    -------
Tenant credit          $400
```

is explained entirely by immutable, balanced journal postings.

At that point Yanushi no longer reconstructs the tenant account from unrelated tables. `Charge` explains **why the tenant owes money**, and the ledger explains **what that obligation did financially**.

Milestone 4 can then replace the temporary payment bridge with the proper `Receipt` domain without changing the definition of tenancy balance.
