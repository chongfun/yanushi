# Implementation Plan: Milestone 4 — Receipts

## Objective

Replace the temporary `TenantPayment` domain with the permanent `Receipt` domain.

At the end of this milestone:

```text
Party (payer)
    │
    ▼
Receipt
├── Tenancy
├── amount_cents
├── received_on
├── payment_method
├── external_reference
└── memo
    │
    ▼
JournalEntry
├── Dr Cash
└── Cr Tenant Receivable
```

A Receipt must preserve:

```text
who paid
which tenancy received the credit
how much was received
when it was received
how it was received
external transaction identity
correction/void history
```

Tenant balance remains:

```text
SUM(Tenant Receivable postings for tenancy)
```

Milestone 4 must not change that definition.

---

# 1. Milestone boundary

Implement:

- `Receipt`
- payer identity
- integer-cent receipt amounts
- ordinary receipt posting
- manual receipt/payment UI
- partial payments
- prepayments
- overpayments
- receipt voiding
- receipt correction/replacement
- immutable receipt history
- receipt PDF
- ingestion confirmation to Receipt
- ingestion duplicate checking against Receipt
- removal of the temporary `TenantPayment` ledger adapter
- deletion of `TenantPayment`

Do not implement:

- receipt-to-charge allocations
- security deposits
- deposit receipts
- returned-check/bank-return accounting
- tenant refunds
- cash-account reconciliation
- arbitrary account selection
- bank accounts
- expense posting
- property ledger migration to journal-entry projections
- final Schedule E accounting semantics
- `SourceDocument` / `ImportedTransaction` redesign

Payment ingestion remains `PaymentIngestion` for now.

---

# 2. Important semantic distinction: correction versus later cash movement

Receipt correction in this milestone means:

```text
"The original accounting record was wrong."
```

Examples:

```text
entered $2,000 instead of $2,100
wrong payer
wrong tenancy
wrong received date
duplicate receipt entered accidentally
```

Correction must **restate the bookkeeping history**.

It does not represent:

```text
payment bounced later
landlord refunded money later
bank reversed transfer later
```

Those are new economic events and must not be modeled as Receipt corrections.

Do not use `Receipts::VoidService` to represent a later real-world cash outflow.

---

# 3. Establish baseline

Before modifying code:

```bash
git status --short

bundle exec rspec
bundle exec rbs validate
bundle exec steep check
bin/rubocop
bin/brakeman --no-pager
```

Then inventory the temporary payment implementation:

```bash
rg -n \
  'TenantPayment|tenant_payment|tenant_payments|TenantPayments::|payment_date|transaction_number' \
  app config db spec sig documentation
```

Pay particular attention to:

```text
TenantPayments::CreateService
TenantPaymentsController
TenantPayments::ReceiptPdfService
PaymentIngestion
PaymentIngestions::ConfirmService
Properties::FinancialItemsQuery
Properties::ActiveYearsQuery
Properties::ScheduleESummaryQuery
Property
Tenancy
User
seeds
```

Do not delete `TenantPayment` until every one of these dependencies has been moved.

---

# 4. Receipt ownership

A Receipt belongs to:

```text
User
Tenancy
payer Party
```

The canonical business ownership remains:

```text
Receipt
  -> Tenancy
    -> RentableUnit
      -> Property
        -> User
```

However, include `user_id` directly on `receipts`.

This is intentional denormalization so the database can enforce user-scoped external transaction uniqueness without relying on an application-level join.

Enforce:

```text
receipt.user_id
==
receipt.tenancy.accounting_user.id
==
receipt.payer_party.user_id
```

`user_id` is immutable.

---

# 5. Create `receipts`

Create:

```text
receipts

id
user_id                NOT NULL
tenancy_id             NOT NULL
payer_party_id         NOT NULL

amount_cents           BIGINT NOT NULL
received_on            DATE NOT NULL
payment_method         NOT NULL
external_reference
memo

posted_at
voided_at
superseded_by_id

created_at             NOT NULL
updated_at             NOT NULL
```

Foreign keys:

```text
user_id          -> users
tenancy_id       -> tenancies
payer_party_id   -> parties
superseded_by_id -> receipts
```

---

# 6. Receipt database constraints

Add:

```text
amount_cents > 0
```

Add indexes:

```text
user_id
tenancy_id
payer_party_id
received_on
voided_at
superseded_by_id
```

Add an active external-reference uniqueness constraint:

```text
UNIQUE (
  user_id,
  payment_method,
  external_reference
)
WHERE
  external_reference IS NOT NULL
  AND voided_at IS NULL
```

Normalize blank references to `NULL`.

This permits:

```text
void erroneous receipt
record corrected replacement using same external reference
```

while still preventing two active receipts from representing the same external transaction.

Add:

```text
UNIQUE(superseded_by_id)
WHERE superseded_by_id IS NOT NULL
```

so one replacement Receipt cannot accidentally serve as the replacement for multiple originals.

---

# 7. Do not require external references

Cash, check, or manually-recorded payments may lack a reliable external identifier.

Therefore:

```text
external_reference is optional
```

Do not use:

```text
amount + date + payer
```

as a hard uniqueness key.

Two legitimate receipts can have exactly the same:

```text
payer
date
amount
method
```

---

# 8. Implement `Receipt`

Create:

```text
app/models/receipt.rb
```

Associations:

```ruby
belongs_to :user
belongs_to :tenancy

belongs_to :payer_party,
  class_name: "Party"

belongs_to :superseded_by,
  class_name: "Receipt",
  optional: true

has_one :superseded_receipt,
  class_name: "Receipt",
  foreign_key: :superseded_by_id

has_many :journal_entries,
  as: :source,
  dependent: :restrict_with_error
```

Implement:

```ruby
def accounting_user
  user
end
```

---

# 9. Receipt validation

Validate:

```text
user present
tenancy present
payer party present

amount_cents > 0
received_on present
payment_method present
```

Ownership validation:

```text
tenancy.accounting_user == user
payer_party.user == user
```

Do **not** require:

```text
payer_party participates in tenancy
```

A payer may legitimately be:

```text
parent
employer
guarantor
organization
other third party
```

The Receipt identifies who sent money.

The Tenancy identifies which account received the credit.

---

# 10. Payment-method semantics

Retain a flexible string field.

Do not make Receipt dependent on a closed enum that cannot represent future payment methods.

Normalize:

```text
strip whitespace
downcase
```

Examples:

```text
cash
check
ach
wire
zelle
venmo
p2p
other
```

The UI may present common choices.

The persistence model should not require a schema change for a new method.

---

# 11. External-reference semantics

Rename the old concept:

```text
transaction_number
```

to:

```text
external_reference
```

because the identifier may come from:

```text
Zelle
Venmo
check number
bank transfer
other external systems
```

Normalize:

```text
strip surrounding whitespace
blank -> nil
```

Do not preserve the old restrictive alphanumeric/dash/underscore format unless there is a demonstrated external-system requirement.

Use a reasonable maximum length, e.g.:

```text
255
```

---

# 12. Receipt amount API

Persist only:

```text
amount_cents
```

Provide presentation helpers:

```ruby
receipt.amount
receipt.amount = "123.45"
```

if useful to existing views/forms.

`amount` should return:

```ruby
BigDecimal(amount_cents.to_s) / 100
```

Parsing must reject values with fractional cents.

For example:

```text
100        valid
100.5      valid -> 10050
100.50     valid -> 10050
100.005    invalid
abc        invalid
0          invalid
negative   invalid
```

Do not silently round user input.

---

# 13. Receipt lifecycle

A Receipt begins:

```text
persisted
posted_at = nil
```

only temporarily inside its creation transaction.

Before transaction commit it must become:

```text
posted_at = journal_entry.posted_at
```

There must be no normal committed state:

```text
Receipt persisted
posted_at nil
JournalEntry absent
```

---

# 14. Posted Receipt immutability

Once posted, the following become immutable:

```text
user_id
tenancy_id
payer_party_id
amount_cents
received_on
payment_method
external_reference
memo
posted_at
```

Ordinary Active Record updates must reject changes.

The only post-posting lifecycle fields are:

```text
voided_at
superseded_by_id
```

and those may only be changed through Receipt lifecycle services.

Direct code such as:

```ruby
receipt.update!(voided_at: Time.current)
```

must fail.

This should follow the same controlled-lifecycle pattern already established for `Charge`.

---

# 15. Receipt scopes/helpers

Implement:

```ruby
scope :active, -> { where(voided_at: nil) }

def posted?
def voided?
def superseded?
```

Avoid persisting redundant statuses such as:

```text
active
corrected
void
```

Lifecycle is derived from existing fields.

---

# 16. Add Receipt associations to domain models

## Tenancy

Replace:

```ruby
has_many :tenant_payments
```

with:

```ruby
has_many :receipts,
  dependent: :restrict_with_error
```

Update:

```ruby
financial_history?
```

to include:

```text
charges
receipts
accounting_postings
```

Remove `tenant_payments`.

## Party

Add:

```ruby
has_many :receipts_as_payer,
  class_name: "Receipt",
  foreign_key: :payer_party_id,
  dependent: :restrict_with_error
```

A Party referenced by historical receipts must not be deleted.

## Property

Replace:

```ruby
has_many :tenant_payments, through: :tenancies
```

with:

```ruby
has_many :receipts, through: :tenancies
```

## User

Replace:

```ruby
has_many :tenant_payments, through: :tenancies
```

with:

```ruby
has_many :receipts, through: :tenancies
```

---

# 17. Create `Receipts::PostService`

Create:

```text
app/services/receipts/post_service.rb
```

For a Receipt:

```text
Dr Cash               +amount_cents
Cr Tenant Receivable  -amount_cents
```

Both PostingSpecs must contain:

```text
tenancy: receipt.tenancy
party: receipt.payer_party
```

`PostingBuilder` will derive:

```text
property
rentable_unit
tenancy
```

The explicit Party dimension preserves payer identity in the ledger.

---

# 18. Receipt journal identity

Use:

```text
source: receipt
event_type: "receipt_posted"
occurred_on: receipt.received_on
```

Use a deterministic description such as:

```text
Payment received - Zelle
Payment received - Cash
Payment received - Check
```

Do not include generated timestamps or mutable Party names in the idempotency-sensitive description.

Payer identity already exists in the Posting dimension.

---

# 19. Create `Receipts::CreateService`

Suggested API:

```ruby
Receipts::CreateService.call(
  tenancy:,
  payer_party:,
  amount: nil,
  amount_cents: nil,
  received_on:,
  payment_method:,
  external_reference: nil,
  memo: nil
)
```

The service owns:

```text
amount parsing
date parsing
ownership validation
Receipt persistence
ledger posting
posted_at transition
```

---

# 20. Receipt creation transaction

Inside one transaction:

1. validate tenancy;
2. derive user from tenancy;
3. validate payer belongs to same user;
4. normalize/validate amount;
5. create Receipt;
6. call `Receipts::PostService`;
7. fail the transaction if accounting posting fails;
8. mark Receipt posted;
9. commit.

Return:

```text
Receipt
JournalEntry
```

through `ServiceResult`.

If accounting fails:

```text
Receipt count unchanged
JournalEntry count unchanged
Posting count unchanged
```

---

# 21. Do not expose accounting primitives to controllers

Correct call graph:

```text
ReceiptsController
      │
      ▼
Receipts::CreateService
      │
      ▼
Receipts::PostService
      │
      ▼
Accounting::PostEntryService
```

Never:

```text
ReceiptsController
  -> Accounting::PostEntryService
```

---

# 22. Running-account behavior remains unchanged

A Receipt never requires a Charge association.

Examples:

```text
Rent charge           +200000 A/R
Receipt               -200000 A/R
Balance                     0
```

Prepayment:

```text
Receipt               -200000
Balance credit         -200000

Later rent            +200000
Balance                      0
```

Overpayment:

```text
Rent                  +200000
Receipt               -250000

Balance                -50000
```

Do not introduce an unapplied-payment liability account in this milestone.

---

# 23. No ReceiptAllocation table yet

Do not create:

```text
ReceiptAllocation
```

unless an implementation dependency proves it necessary.

Current balance correctness must remain completely independent of allocation.

The PRD explicitly keeps receipt-to-charge matching optional for MVP.

---

# 24. Manual Receipt UI

Replace:

```text
TenantPaymentsController
tenant_payments views
tenant_payment routes
```

with:

```text
ReceiptsController
receipts views
receipt routes
```

User-facing wording may continue saying:

```text
Payment
Record Payment
Payment Details
```

where that is clearer.

Internal domain vocabulary should be:

```text
Receipt
```

---

# 25. Receipt routes

Target:

```ruby
resources :tenancies do
  resources :receipts, only: %i[new create]
end

resources :receipts, only: %i[index show new create] do
  member do
    get :correction
    post :correct
    post :void
  end
end
```

Do not provide:

```text
edit
update
destroy
```

for posted receipts.

---

# 26. Manual Receipt form

Fields:

```text
Tenancy
Payer
Received on
Amount
Payment method
External reference
Memo
```

When nested beneath a tenancy:

```text
tenancy is fixed
```

or clearly displayed and hidden from ordinary reassignment.

The correction workflow is the place for fixing an incorrectly-selected tenancy.

---

# 27. Payer selection

The payer picker should include **all Parties belonging to the user**, not only tenancy participants.

To make the common case convenient:

If the tenancy has exactly one active:

```text
TenancyParty(role: tenant)
```

on the relevant date, preselect that Party.

If multiple tenant-role Parties are active:

```text
do not guess
```

Require the user to choose.

If the actual payer is an external Party:

```text
parent
company
guarantor
etc.
```

allow selecting that Party.

---

# 28. Joint-tenancy requirement

Explicitly test:

```text
Tenancy:
  Alice
  Bob

Receipt 1:
  payer = Alice
  amount = $1,000

Receipt 2:
  payer = Bob
  amount = $1,000
```

Both reduce:

```text
the same Tenancy Receivable balance
```

while preserving different payer identities.

This is a primary Milestone 4 acceptance criterion.

---

# 29. Receipt detail page

Show:

```text
Amount
Received date
Payer
Payment method
External reference
Memo
Property
Unit
Tenancy
Posted status
Void/correction history
```

If corrected:

```text
This payment was corrected.
Replacement: Receipt #...
```

If it supersedes another:

```text
This payment replaces Receipt #...
```

If voided without replacement:

```text
Voided
```

Historical Receipts remain directly viewable.

---

# 30. Receipt PDF

Replace:

```text
TenantPayments::ReceiptPdfService
```

with:

```text
Receipts::PdfService
```

or:

```text
Receipts::ReceiptPdfService
```

PDF should include:

```text
Payment Receipt
Received date
Amount
Payer
Method
External reference
Property
Unit
Tenancy reference
Receipt ID
```

A corrected/voided Receipt PDF should visibly indicate that it is no longer the active version.

Do not silently print a voided receipt as if it were current.

---

# 31. Implement `Receipts::VoidService`

Void means:

```text
remove an erroneously-recorded Receipt from accounting history
```

Suggested API:

```ruby
Receipts::VoidService.call(
  receipt:,
  reason: nil
)
```

Inside one transaction:

1. lock Receipt;
2. reject an already-superseded Receipt;
3. find its `receipt_posted` JournalEntry;
4. reverse that entry;
5. use:
   ```text
   reversal occurred_on = receipt.received_on
   ```
6. mark Receipt `voided_at`;
7. commit.

---

# 32. Why void reversal uses the original received date

This is deliberate bookkeeping restatement.

Suppose a duplicate `$2,000` Receipt was accidentally entered January 10 and discovered February 1.

If the correction reversal were dated February 1:

```text
January as-of reports would continue showing the duplicate.
```

Instead:

```text
original posting Jan 10
reversal posting Jan 10
```

net to zero in historical financial reporting.

Audit chronology is still preserved through:

```text
JournalEntry.posted_at
Receipt.voided_at
```

This distinguishes:

```text
accounting correction
```

from:

```text
actual later cash refund/reversal
```

---

# 33. Receipt void idempotency

Calling void twice must not create two reversals.

If already voided with no replacement:

```text
return existing reversal successfully
```

if the request is semantically identical.

Do not create multiple reversal entries.

---

# 34. Implement `Receipts::CorrectService`

Suggested API:

```ruby
Receipts::CorrectService.call(
  receipt:,
  tenancy:,
  payer_party:,
  amount:,
  received_on:,
  payment_method:,
  external_reference:,
  memo:
)
```

The replacement may correct:

```text
amount
payer
tenancy
received date
method
external reference
memo
```

---

# 35. Receipt correction transaction

Within one transaction:

1. lock original Receipt;
2. reject if it has already been voided without replacement;
3. if already superseded:
   - compare requested replacement with existing replacement;
   - identical => idempotent success;
   - different => conflict;
4. reverse original journal entry at original `received_on`;
5. mark original `voided_at`;
6. create/post replacement Receipt;
7. set:
   ```text
   original.superseded_by_id = replacement.id
   ```
8. commit.

If any step fails:

```text
original remains active
no reversal remains
no replacement remains
```

---

# 36. Correction cash semantics

Example:

Original:

```text
Receipt A
$2,000
Jan 5

Dr Cash               +200000
Cr Tenant Receivable  -200000
```

Corrected to:

```text
Receipt B
$2,100
Jan 5
```

Correction creates:

```text
Reversal of A:
Dr Tenant Receivable  +200000
Cr Cash               -200000

Receipt B:
Dr Cash               +210000
Cr Tenant Receivable  -210000
```

Net:

```text
Cash                 +210000
Tenant Receivable    -210000
```

Original financial history remains visible.

---

# 37. Correcting the tenancy

Allow correction to another tenancy belonging to the same user.

Example:

```text
Receipt mistakenly applied to Unit A
should have been Unit B
```

Result:

```text
reverse A/R credit on Unit A
post replacement A/R credit on Unit B
```

Cash nets unchanged.

Do not support moving a Receipt to another user's tenancy.

---

# 38. Correcting the payer

Allow payer correction.

Example:

```text
Receipt was recorded as Alice
actual payer was Bob
```

Replacement postings carry Bob as the Party dimension.

Original postings remain historically attached to Alice but are reversed exactly.

---

# 39. Correction UI

Do not reuse a generic edit form.

Provide:

```text
Correct Payment
```

with explanatory copy that correction:

```text
keeps the original record
reverses its accounting
creates a replacement
```

Prefill the current Receipt values.

On success redirect to the replacement Receipt.

Show a link back to the original.

---

# 40. Void UI

Provide:

```text
Void Payment
```

with explicit wording:

```text
Use this only if the payment record itself was entered in error.
Do not use this for money later returned to a payer.
```

Require confirmation.

An optional reason may be retained in UI/audit text, but do not overload `memo` on the original Receipt.

If storing correction reason becomes useful, add a dedicated lifecycle/audit field rather than rewriting the original memo.

---

# 41. Retarget PaymentIngestion

Keep the model name:

```text
PaymentIngestion
```

for this milestone.

Change:

```text
tenant_payment_id
```

to:

```text
receipt_id
```

Association:

```ruby
belongs_to :receipt, optional: true
```

Remove the TenantPayment association.

---

# 42. Payment ingestion confirmation

Update:

```text
PaymentIngestions::ConfirmService
```

to create a Receipt.

Map:

```text
ingestion.tenancy
  -> receipt.tenancy

ingestion.party
  -> receipt.payer_party

ingestion.amount
  -> receipt amount

ingestion.payment_date
  -> receipt.received_on

ingestion.payment_method
  -> receipt.payment_method

ingestion.transaction_number
  -> receipt.external_reference
```

The parsed:

```text
payer_name
payer_username
raw_text
```

remain immutable source/provenance information on the ingestion.

---

# 43. Ingestion confirmation must remain atomic

Inside the existing ingestion transaction:

1. lock ingestion;
2. verify confirmable;
3. create/post Receipt;
4. optionally create Party aliases;
5. set:
   ```text
   status = confirmed
   receipt_id = receipt.id
   ```
6. commit.

If Receipt posting fails:

```text
ingestion remains unconfirmed
Receipt rolls back
JournalEntry rolls back
Posting rolls back
aliases roll back
```

---

# 44. Make repeated confirmation idempotent

The current behavior treats "already confirmed" as an error.

Change it.

If:

```text
ingestion.confirmed?
AND ingestion.receipt exists
```

then repeated confirmation should:

```text
return existing Receipt successfully
```

without creating anything.

If:

```text
confirmed?
but receipt_id missing/broken
```

return an integrity failure.

Do not silently create another Receipt.

The architecture PRD explicitly requires repeated ingestion confirmation not to duplicate financial effects.

---

# 45. Ingestion provenance after correction

If an ingestion originally confirmed:

```text
Receipt A
```

and Receipt A is later corrected to Receipt B:

```text
PaymentIngestion.receipt_id remains A
```

Do not rewrite it to B.

That preserves:

```text
"This ingestion confirmation created Receipt A."
```

Receipt A then points through:

```text
superseded_by -> Receipt B
```

The UI may resolve/display the current replacement, but provenance should not be rewritten.

---

# 46. Ingestion duplicate detection

Replace every query against:

```text
TenantPayment
```

with:

```text
Receipt
```

The canonical external duplicate check becomes:

```text
user_id
payment_method
external_reference
active Receipt
```

The database partial unique index remains the concurrency protection.

Do not derive uniqueness from amount/date/payer.

---

# 47. Keep parsed identity separate from durable payer identity

`PaymentIngestion` retains:

```text
payer_name
payer_username
```

Receipt stores:

```text
payer_party_id
```

Do not copy the parser's free-form payer name into Receipt as another mutable truth field.

The ingestion explains:

```text
what the source document said
```

The Receipt explains:

```text
which Party Yanushi confirmed as payer
```

---

# 48. Retarget property financial items

Replace:

```text
tenant_payments
payment_date
"Tenant Payment"
```

with:

```text
receipts
received_on
"Payment"
```

in:

```text
Properties::FinancialItemsQuery
```

The UI can continue showing a green "Payment" row.

Show:

```text
payer display name
payment method
```

where useful.

Mark:

```text
voided
corrected
```

records appropriately rather than making them disappear from audit-oriented history.

---

# 49. Active-year query

Replace:

```text
years_for(:tenant_payments, :payment_date)
```

with:

```text
years_for(:receipts, :received_on)
```

Do not lose years that contain only Receipt activity.

---

# 50. Interim Schedule E query

The final tax-reporting redesign is not Milestone 4.

However, deleting `TenantPayment` requires preserving current behavior.

Replace the current temporary:

```text
property.tenant_payments
```

query with:

```text
property.receipts.active
```

for the same interim "rents received" calculation.

Use:

```text
received_on
amount_cents
```

and convert from cents only at the query result boundary.

Do **not** claim this is the final Schedule E architecture.

Milestone 9 still owns the explicit tax-reporting projection.

---

# 51. Void/corrected Receipts and interim reports

A pure voided Receipt must contribute:

```text
$0
```

to current interim received-rent reporting.

A corrected Receipt contributes only its active replacement amount.

Therefore the temporary Schedule E query should use:

```text
Receipt.active
```

rather than summing all Receipt source rows.

This is an interim domain-table query only.

The tenancy balance does **not** use this filter because reversals already make the accounting ledger net correctly.

---

# 52. Tenant balance requires no redesign

Do not alter the existing ledger-backed tenancy balance algorithm.

Receipt posting already uses:

```text
Tenant Receivable
```

so:

```text
partial payment
prepayment
overpayment
void
correction
```

all naturally change balance through postings.

No `Receipt` table query belongs in `Tenancies::BalanceQuery`.

---

# 53. Payment form prefill

Preserve current behavior:

```text
if tenancy balance > 0:
  default amount = amount owed

if tenancy balance <= 0:
  default amount = 0
```

Do not cap the submitted amount.

An overpayment is explicitly valid.

---

# 54. Replace modal payment flows

Update the property financial modal:

```text
Record Payment
```

to use:

```text
new_tenancy_receipt_path
```

On successful Receipt creation, refresh:

```text
property financials
active tenancy balances
flash
```

as the current TenantPayment flow does.

Keep the UX behavior; replace only the domain source.

---

# 55. Seeds

Replace seeded TenantPayments with:

```text
Receipts::CreateService
```

Supply explicit payer Party.

Do not seed Receipt rows directly.

Do not manually seed balancing JournalEntries.

Development seed state must satisfy the same:

```text
Receipt + ledger atomicity
```

as normal application behavior.

---

# 56. Delete the temporary payment bridge

Delete:

```text
TenantPayments::CreateService
TenantPayments::PostLegacyService
```

or whatever transitional posting classes remain.

There must be exactly one normal money-receipt posting path:

```text
Receipts::CreateService
  -> Receipts::PostService
```

Do not keep aliases or forwarding wrappers.

---

# 57. Delete `TenantPayment`

After all callers are migrated:

Delete:

```text
app/models/tenant_payment.rb
app/controllers/tenant_payments_controller.rb
app/views/tenant_payments/
TenantPayments::* services
tenant payment factories
tenant payment specs
tenant payment RBS
tenant payment routes
```

Drop:

```text
tenant_payments
```

from the database.

No compatibility constant:

```ruby
TenantPayment = Receipt
```

---

# 58. No legacy `TenantPayment` journal sources

Because there is no production data to preserve, do not build a backfill.

Use a clean database during development/test cutover.

After the transition there should be no newly-created:

```text
JournalEntry.source_type = "TenantPayment"
```

All ordinary payment entries must be:

```text
source_type = "Receipt"
event_type = "receipt_posted"
```

---

# 59. Development database policy

Because the project still has no production data requiring preservation, prefer:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate
```

after the destructive schema cutover.

Do not add dual-write or source-type backfill machinery solely to preserve disposable development records.

---

# 60. Receipt model tests

Test:

- requires User;
- requires Tenancy;
- requires payer Party;
- requires positive cents;
- requires received date;
- requires payment method;
- external reference optional;
- blank external reference normalizes nil;
- user must match tenancy owner;
- payer must belong to same user;
- payer need not participate in tenancy;
- individual payer works;
- organization payer works;
- active duplicate external reference fails;
- same reference for another user succeeds;
- voided external reference may be reused;
- posted financial fields cannot mutate;
- direct `voided_at` mutation fails;
- direct `superseded_by_id` mutation fails;
- destroy fails after posting.

---

# 61. Receipt posting tests

For `$2,000`:

```text
Cash               +200000
Tenant Receivable  -200000
```

Verify both lines carry:

```text
property
rentable_unit
tenancy
payer party
```

Verify:

```text
source_type = Receipt
event_type = receipt_posted
occurred_on = received_on
```

---

# 62. Receipt creation atomicity tests

Force Receipt validation failure:

```text
no JournalEntry
no Posting
```

Force accounting failure:

```text
no committed Receipt
no JournalEntry
no Posting
```

Successful create:

```text
one Receipt
one JournalEntry
two Postings
posted_at set
```

---

# 63. Joint-payer test

Given:

```text
Alice and Bob share one tenancy.
```

Create:

```text
Receipt Alice $500
Receipt Bob   $700
```

Assert:

```text
same tenancy balance reduced by $1,200
Alice retained on first Receipt/postings
Bob retained on second Receipt/postings
```

---

# 64. Non-tenant payer test

Create:

```text
Party: Alice's Employer
not a TenancyParty
```

Record:

```text
$2,000 Receipt
payer = Employer
tenancy = Alice's tenancy
```

Assert:

```text
valid
tenant balance reduced
payer preserved
```

This proves Party and tenancy role are not incorrectly conflated.

---

# 65. Partial-payment test

```text
Rent Charge      +$2,000
Receipt            -$500

Balance           +$1,500
```

---

# 66. Prepayment test

```text
Receipt          -$2,000
Balance          -$2,000 credit

Later Rent       +$2,000
Balance                $0
```

No allocation exists.

---

# 67. Overpayment test

```text
Rent             +$2,000
Receipt          -$2,500

Balance            -$500 credit
```

No liability reclassification is created.

---

# 68. Receipt void tests

Test:

- original Receipt remains;
- original JournalEntry remains;
- reversal exists;
- reversal uses original accounting date;
- amounts negate exactly;
- party dimensions negate exactly;
- Receipt gets `voided_at`;
- balance updates automatically;
- duplicate void is idempotent;
- direct source deletion remains impossible.

---

# 69. Receipt correction tests

Original:

```text
$2,000
```

Correct to:

```text
$2,100
```

Assert:

```text
original Receipt remains
original JournalEntry remains
reversal exists
replacement Receipt exists
replacement JournalEntry exists
original.superseded_by = replacement
original.voided_at present
```

Net ledger:

```text
Cash               +$2,100
Tenant Receivable  -$2,100
```

---

# 70. Correction-to-other-tenancy test

Record Receipt against:

```text
Tenancy A
```

Correct it to:

```text
Tenancy B
```

Assert:

```text
Tenancy A credit is reversed
Tenancy B receives credit
Cash net unchanged
```

---

# 71. Correction-to-other-payer test

Correct:

```text
payer Alice -> payer Bob
```

Assert:

```text
original ledger preserved/reversed with Alice
replacement ledger carries Bob
```

---

# 72. Correction idempotency test

Submit identical correction twice.

Expected:

```text
one reversal
one replacement Receipt
one replacement JournalEntry
```

Second call returns existing replacement.

Submit a different second correction against the already-corrected original.

Expected:

```text
conflict
```

Do not create another sibling replacement.

---

# 73. Correction concurrency test

Two concurrent correction attempts against the same Receipt must serialize through the original Receipt lock.

Result must be:

```text
one winning replacement
one reversal
```

The loser either:

```text
returns the same replacement if equivalent
```

or:

```text
fails with correction conflict
```

Never create two replacements.

---

# 74. Void-versus-correct concurrency test

Concurrent:

```text
VoidService
CorrectService
```

against one Receipt must not produce:

```text
one pure void
plus one replacement
```

Locking must establish one terminal outcome.

---

# 75. External-reference correction test

Original active Receipt:

```text
method: zelle
external_reference: ABC123
```

Correction may create replacement with:

```text
method: zelle
external_reference: ABC123
```

because the original is voided inside the same transaction before the replacement becomes active.

Prove the partial unique index supports this.

---

# 76. Payment-ingestion tests

Test:

- matched ingestion creates Receipt;
- ingestion Party becomes payer;
- ingestion Tenancy becomes Receipt tenancy;
- amount maps correctly to integer cents;
- payment date maps to received date;
- transaction number maps to external reference;
- payer source text remains on ingestion;
- aliases still work;
- confirmation posts accounting exactly once;
- repeated confirmation returns same Receipt;
- duplicate external transaction cannot create second active Receipt;
- confirmation failure rolls everything back.

---

# 77. Ingestion correction provenance test

Confirm ingestion:

```text
ingestion -> Receipt A
```

Correct Receipt A to Receipt B.

Assert:

```text
ingestion.receipt == Receipt A
Receipt A.superseded_by == Receipt B
```

Do not rewrite ingestion provenance.

---

# 78. Receipt UI request/system scenarios

## Manual payment

1. Open tenancy.
2. Click Record Payment.
3. Select payer.
4. Enter amount/method/reference.
5. Submit.
6. Receipt appears.
7. Tenancy balance changes.

## Joint tenants

1. Tenancy has Alice and Bob.
2. Record Alice payment.
3. Record Bob payment.
4. Both identify payer correctly.

## Third-party payer

1. Choose non-tenant Party.
2. Record payment.
3. Receipt succeeds.

## Overpayment

1. Tenant owes $500.
2. Record $750.
3. Account shows $250 credit.

## Correction

1. Open Receipt.
2. Click Correct Payment.
3. Change amount.
4. Original becomes corrected.
5. Replacement appears.
6. Balance reflects replacement only.

## Void

1. Open erroneous Receipt.
2. Void it.
3. Receipt remains visible.
4. Balance reverses.

---

# 79. PDF request coverage

Render PDF for:

```text
active Receipt
corrected original
replacement Receipt
voided Receipt
```

Verify payer is included.

Verify corrected/voided history cannot be mistaken for an active current payment receipt.

---

# 80. Update property financial UI

Replace branches checking:

```text
"Tenant Payment"
```

with:

```text
"Payment"
```

Display:

```text
payer
method
```

where useful.

Use:

```text
Receipt#amount
```

for formatting.

Voided/corrected source rows should be clearly marked if shown.

---

# 81. Update active-year behavior

Tests must prove a year containing:

```text
Receipt activity only
```

still appears in the financial year selector.

---

# 82. Update interim Schedule E tests

Until the tax milestone:

```text
active ordinary Receipt
```

contributes to the existing rents-received number.

Test:

```text
active Receipt      included
voided Receipt      excluded
corrected original  excluded
replacement         included
```

Do not introduce tax-accounting redesign here.

---

# 83. Update factories

Delete:

```text
:tenant_payment
```

Add:

```text
:receipt
```

Traits:

```text
:posted_receipt
:voided_receipt
:corrected_receipt
```

For tests requiring a financially-real Receipt, prefer:

```text
Receipts::CreateService
```

instead of factory-only persistence.

Direct factory creation is appropriate for isolated validation tests.

---

# 84. Update RBS

Add/update:

```text
Receipt

Receipts::CreateService
Receipts::PostService
Receipts::VoidService
Receipts::CorrectService
Receipts::PdfService

ReceiptsController
```

Update:

```text
PaymentIngestion
PaymentIngestions::ConfirmService
Property
Tenancy
Party
User
Properties::FinancialItemsQuery
Properties::ActiveYearsQuery
Properties::ScheduleESummaryQuery
```

Delete:

```text
TenantPayment
TenantPayments::*
TenantPaymentsController
```

Regenerate Rails signatures:

```bash
bin/rails rbs_rails:all

bundle exec rbs validate
bundle exec steep check
```

Keep broad Steep coverage.

---

# 85. Documentation

Add:

```text
documentation/double_entry_accounting/implementation_plan_milestone_4.md
```

Update accounting architecture documentation with:

```text
Receipt versus Charge

payer Party versus tenancy participants

Receipt posting rule

running-account semantics

overpayments

Receipt lifecycle

correction versus later cash refund

source-event immutability

ingestion provenance

no allocations yet
```

Explicitly state:

```text
A Receipt means ordinary money received and credited to a tenancy.

A refundable security deposit is not a Receipt.
```

Milestone 6 owns deposit money.

---

# 86. Search for stale TenantPayment vocabulary

Run:

```bash
rg -n \
  'TenantPayment|tenant_payment|tenant_payments|TenantPayments::' \
  app config db spec sig
```

Expected:

```text
no live application-code hits
```

Historical architecture documentation may mention it as a removed model.

---

# 87. Search for old payment-field names

Run:

```bash
rg -n \
  'payment_date|transaction_number' \
  app config db spec sig
```

Review every hit.

Payment ingestion parser fields may legitimately remain:

```text
payment_date
transaction_number
```

because those are source/parser vocabulary.

Receipt code must use:

```text
received_on
external_reference
```

Do not blindly rename parser-source fields if doing so adds no domain value.

---

# 88. Ensure Receipt creation is service-owned

Run:

```bash
rg -n \
  'Receipt\.(new|create|create!)|receipts\.(build|create|create!)' \
  app
```

Review every production hit.

No controller or ingestion service should directly persist Receipt.

All financially-real Receipt creation must go through:

```text
Receipts::CreateService
```

Correction may call that service internally.

---

# 89. Verify accounting creation remains contained

Run:

```bash
rg -n \
  'Posting\.(create|create!|new)|postings\.(create|create!|build)|JournalEntry\.(create|create!|new)' \
  app
```

Receipt services must still delegate to Milestone 2 accounting services.

Do not leak direct accounting persistence into the new domain services.

---

# 90. Verify no balance query reads Receipts

Run:

```bash
rg -n \
  'Receipt|receipts' \
  app/queries/tenancies
```

The tenancy balance query should not need Receipt rows.

It should continue reading:

```text
Tenant Receivable postings
```

only.

---

# 91. Clean database verification

Run:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate
```

Verify:

```text
receipts exists
tenant_payments does not exist
payment_ingestions.receipt_id exists
payment_ingestions.tenant_payment_id does not exist
```

---

# 92. Manual smoke test

Using a clean database:

1. Create property/unit/tenancy.
2. Ensure rent charge exists.
3. Create Alice Party.
4. Create Bob Party.
5. Add Alice/Bob to tenancy.
6. Record payment from Alice.
7. Verify payer is Alice.
8. Verify balance decreases.
9. Record payment from Bob.
10. Verify payer is Bob.
11. Create Employer Party not on tenancy.
12. Record payment from Employer.
13. Verify it succeeds.
14. Overpay the account.
15. Verify negative tenant balance/credit.
16. Correct one payment amount.
17. Verify original remains and replacement is linked.
18. Verify balance reflects corrected amount only.
19. Correct a payment to another tenancy.
20. Verify receivable moves between tenancies while cash stays net unchanged.
21. Void an erroneous payment.
22. Verify balance reverses.
23. Upload and confirm an ingestion.
24. Verify its Party becomes Receipt payer.
25. Confirm the same ingestion again.
26. Verify no duplicate Receipt/posting.
27. Download a Receipt PDF.
28. Open property financial history.
29. Open Schedule E interim view.
30. Confirm no TenantPayment UI/model remains.

---

# 93. Final quality gate

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

Coverage must remain above the CI threshold.

---

# 94. Suggested commit boundaries

## Commit 1: Add Receipt domain

Include:

```text
receipts migration
Receipt model
associations
amount parsing
ownership
lifecycle protection
model specs
```

## Commit 2: Add Receipt accounting

Include:

```text
Receipts::PostService
Receipts::CreateService
posting specs
atomicity tests
payer dimensions
running-account scenarios
```

## Commit 3: Replace manual TenantPayment flow

Include:

```text
ReceiptsController
routes
forms
views
PDF
property financial UI
manual-payment tests
```

## Commit 4: Add void and correction

Include:

```text
Receipts::VoidService
Receipts::CorrectService
correction UI
void UI
lifecycle tests
concurrency tests
```

## Commit 5: Move ingestion to Receipt

Include:

```text
payment_ingestions.receipt_id
ConfirmService
duplicate detection
idempotent confirmation
provenance tests
```

## Commit 6: Remove TenantPayment

Include:

```text
TenantPayment model deletion
TenantPayments services deletion
old routes/views/specs/signatures deletion
associations/query updates
```

## Commit 7: Reporting compatibility and cleanup

Include:

```text
FinancialItemsQuery
ActiveYearsQuery
interim Schedule E query
seeds
RBS
Steep
documentation
stale-reference cleanup
full quality gate
```

Each commit should remain green where practical.

---

# 95. Milestone 4 acceptance checklist

## Receipt domain

- [ ] `Receipt` exists.
- [ ] `TenantPayment` does not.
- [ ] Amount uses integer cents.
- [ ] Receipt preserves payer Party.
- [ ] Receipt belongs to Tenancy.
- [ ] Payer need not be a tenancy participant.
- [ ] User/Tenancy/Payer ownership is consistent.
- [ ] Received date is preserved.
- [ ] Payment method is preserved.
- [ ] External reference is preserved.
- [ ] Memo is supported.
- [ ] Posted Receipt financial fields are immutable.
- [ ] Receipt cannot be hard-deleted.

## Accounting

- [ ] Receipt posts Dr Cash.
- [ ] Receipt posts Cr Tenant Receivable.
- [ ] Receipt postings carry Property/Unit/Tenancy dimensions.
- [ ] Receipt postings carry payer Party dimension.
- [ ] Receipt creation and posting are atomic.
- [ ] Tenant balance still comes solely from ledger postings.

## Running account

- [ ] Partial payment works.
- [ ] Prepayment works.
- [ ] Overpayment works.
- [ ] Negative balance represents tenant credit.
- [ ] No charge allocation is required.

## Payer identity

- [ ] Joint tenants can each make payments.
- [ ] Their payments affect the same tenancy balance.
- [ ] Actual payer remains distinguishable.
- [ ] Non-tenant Party may pay.
- [ ] Organization Party may pay.

## Corrections

- [ ] Original Receipt remains.
- [ ] Original JournalEntry remains.
- [ ] Correction creates reversal.
- [ ] Correction creates replacement Receipt.
- [ ] Replacement gets a new JournalEntry.
- [ ] Original links to replacement.
- [ ] Correct amount is reflected.
- [ ] Correct payer is reflected.
- [ ] Correct tenancy is reflected.
- [ ] Correction is transactional.
- [ ] Concurrent corrections cannot create siblings.

## Voiding

- [ ] Void creates accounting reversal.
- [ ] Receipt remains as history.
- [ ] Balance updates automatically.
- [ ] Void is idempotent.
- [ ] Void is documented as correction, not later cash refund.

## External identity

- [ ] Active external references are unique per user/method.
- [ ] Legitimate repeated payments without references are allowed.
- [ ] A voided external reference may be reused.
- [ ] Corrected replacement may retain the original external reference.

## Ingestion

- [ ] PaymentIngestion references Receipt.
- [ ] Confirming creates Receipt.
- [ ] Parsed Party becomes payer.
- [ ] Parsed payer-name/user-name snapshots remain on ingestion.
- [ ] Confirmation is atomic.
- [ ] Repeated confirmation returns the same Receipt.
- [ ] Duplicate confirmation cannot duplicate ledger postings.
- [ ] Correcting Receipt does not rewrite ingestion provenance.

## UI

- [ ] Record Payment uses Receipt internally.
- [ ] Payer is selected/displayed.
- [ ] Single active tenant may be preselected.
- [ ] Multiple tenants are not guessed.
- [ ] Receipt detail works.
- [ ] PDF includes payer.
- [ ] Correct Payment workflow works.
- [ ] Void Payment workflow works.
- [ ] Corrected/voided records are visibly historical.

## Legacy cleanup

- [ ] `tenant_payments` table is gone.
- [ ] `TenantPayment` constant is gone.
- [ ] `TenantPaymentsController` is gone.
- [ ] TenantPayment services are gone.
- [ ] Temporary legacy posting adapter is gone.
- [ ] No newly-created `JournalEntry` uses `TenantPayment` as source.
- [ ] Property/User/Tenancy associations use Receipts.
- [ ] FinancialItemsQuery uses Receipts.
- [ ] ActiveYearsQuery uses Receipts.
- [ ] Interim Schedule E query uses active Receipts.

## Quality

- [ ] Receipt model specs pass.
- [ ] Posting specs pass.
- [ ] Atomicity specs pass.
- [ ] Running-account specs pass.
- [ ] Correction specs pass.
- [ ] Correction concurrency specs pass.
- [ ] Ingestion specs pass.
- [ ] Request/system specs pass.
- [ ] PDF specs pass.
- [ ] RBS validates.
- [ ] Steep passes.
- [ ] RuboCop passes.
- [ ] RSpec passes.
- [ ] Coverage remains above CI threshold.
- [ ] Security scans pass.

---

# 96. Desired end state

After Milestone 4:

```text
Tenancy
├── Charges
│   ├── Rent
│   ├── Late fee
│   ├── Reimbursement
│   └── Other
│
└── Receipts
    ├── payer Party
    └── immutable correction chain
```

Financially:

```text
Rent Charge
  Dr Tenant Receivable
  Cr Rental Income

Receipt
  Dr Cash
  Cr Tenant Receivable
```

A shared tenancy can therefore have:

```text
Rent Charge                +$2,000

Alice Receipt                -$500
Bob Receipt                  -$750
Employer Receipt             -$750

Balance                         $0
```

without pretending all three payments came from the same tenant.

If Bob's payment was really `$700`, Yanushi preserves:

```text
original Bob Receipt
original journal entry
reversal
replacement Bob Receipt
replacement journal entry
```

rather than editing financial history.

At that point the temporary payment bridge is gone. `Charge` explains why money is owed, `Receipt` explains who paid money into the tenancy account, and the immutable accounting ledger remains the single source of truth for the resulting balance.
