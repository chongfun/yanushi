# Implementation Plan: Milestone 2 — Accounting Foundation

## 1. Objective

At the end of this milestone, Yanushi should have this infrastructure:

```text
User
├── Account
│
└── JournalEntry
    └── Posting
        ├── Account
        ├── Property?
        ├── RentableUnit?
        ├── Tenancy?
        └── Party?
```

and these application services:

```text
Accounting::ChartOfAccounts
Accounting::PostingSpec
Accounting::PostingBuilder
Accounting::PostEntryService
Accounting::ReverseEntryService
```

The system must guarantee, through those boundaries:

```text
every posted journal entry balances

posting the same source event twice is idempotent

conflicting reuse of an idempotency key fails loudly

journal entries and postings cannot be edited or deleted

reversals preserve the original entry

dimensions belong to the same user and form a consistent hierarchy

entries and postings are persisted atomically
```

Milestone 2 should **not change any current property, tenancy, payment, expense, ingestion, Schedule E, or dashboard behavior**.

---

# 2. Read and establish the baseline

Before making changes, inspect:

```text
db/schema.rb

app/models/user.rb
app/models/property.rb
app/models/rentable_unit.rb
app/models/tenancy.rb
app/models/party.rb

app/services/service_result.rb
app/services/service_result_types.rb

spec/factories.rb

sig/README.md
Steepfile
.github/workflows/ci.yml
```

The current `User` already acts as the ownership root for properties, parties, and the surviving financial models. Accounts and journal entries should use that same ownership root rather than being property-owned. 

Run:

```bash
git status --short
bundle exec rspec
bundle exec rbs validate
bundle exec steep check
bin/rubocop
bin/brakeman --no-pager
```

Record any pre-existing failures.

CI currently requires the complete RSpec suite, Steep, RuboCop, security scans, and at least 95% line coverage. 

---

# 3. Explicit Milestone 2 design decisions

Treat these as fixed decisions unless implementation uncovers a genuine contradiction.

### Ledger ownership

Accounts and journal entries belong to `User`.

Do **not** create one chart of accounts per property.

Property, unit, tenancy, and party are posting dimensions.

### Amount representation

All ledger amounts use:

```text
bigint amount_cents
```

Convention:

```text
positive = debit
negative = credit
```

A zero posting is invalid.

### Entry balancing

For every journal entry:

```text
sum(postings.amount_cents) == 0
```

and there must be at least two postings.

### Drafts

There are no persisted draft journal entries.

Build the complete entry in memory, validate it, and atomically persist the journal entry plus all postings.

### Immutability

Once persisted:

```text
JournalEntry cannot be updated
JournalEntry cannot be destroyed

Posting cannot be updated
Posting cannot be destroyed
```

Corrections occur through reversal/new events later.

### Idempotency

The identity of a posting event is:

```text
user
source_type
source_id
event_type
```

That tuple must be unique.

### Reversal

A reversal is itself a new journal entry.

It contains exactly the negation of the original postings.

The original entry remains untouched.

### Dimensions

Canonical hierarchy:

```text
Tenancy
  -> RentableUnit
    -> Property
```

If a caller supplies `tenancy`, the accounting layer derives its unit and property.

If a caller supplies `rentable_unit`, the accounting layer derives its property.

If callers redundantly provide parent dimensions, they must match.

### No ledger integration yet

Existing `TenantPayment`, `Expense`, `TenantCharge`, `ScheduledRent`, and ingestion flows continue behaving exactly as today.

Milestones 3+ will post their replacement domain events.

---

# 4. Create the accounting schema

Create one migration for the Milestone 2 accounting foundation.

Do not modify existing financial tables.

## 4.1 `accounts`

Create:

```text
accounts

id
user_id          NOT NULL
key              NOT NULL
name             NOT NULL
account_type     NOT NULL
active           NOT NULL DEFAULT true
created_at       NOT NULL
updated_at       NOT NULL
```

Add:

```text
FK user_id -> users
unique index(user_id, key)
index(user_id)
```

Add a database check restricting `account_type` to:

```text
asset
liability
equity
income
expense
```

Do not add a property ID.

Do not add mutable account numbers or arbitrary hierarchy yet.

---

# 5. Define the system chart of accounts

Create:

```text
app/services/accounting/chart_of_accounts.rb
```

Centralize definitions there rather than scattering account strings throughout application code.

Initial definitions:

```text
cash
  Cash
  asset

tenant_receivable
  Tenant Receivable
  asset

security_deposits_held
  Security Deposits Held
  liability

rental_income
  Rental Income
  income

late_fee_income
  Late Fee Income
  income

reimbursement_income
  Reimbursement Income
  income

expense_advertising
  Advertising
  expense

expense_cleaning_maintenance
  Cleaning and Maintenance
  expense

expense_insurance
  Insurance
  expense

expense_legal_professional
  Legal and Professional
  expense

expense_management
  Management
  expense

expense_repairs
  Repairs
  expense

expense_supplies
  Supplies
  expense

expense_taxes
  Taxes
  expense

expense_utilities
  Utilities
  expense

expense_other
  Other Expense
  expense

opening_balance_equity
  Opening Balance Equity
  equity
```

Provision all of these now even though later milestones will use them incrementally.

That avoids changing the accounting vocabulary every time another financial source starts posting.

---

# 6. Implement `Account`

Create:

```text
app/models/account.rb
```

Associations:

```ruby
belongs_to :user
has_many :postings, dependent: :restrict_with_error
```

Use a string-backed validated enum for `account_type`, consistent with the Milestone 1 enum pattern.

Validate:

```text
user present
key present
key format: lowercase letters/numbers/underscores only
key unique within user
name present
account_type valid
```

Normalize:

```text
key -> strip/downcase
name -> strip
```

Once created, these fields are accounting identity and should not change:

```text
user_id
key
account_type
```

Allow later modification of:

```text
name
active
```

Do not build an account-management UI.

Do not permit account deletion once postings exist.

---

# 7. Provision accounts for every user

`Accounting::ChartOfAccounts` should expose something equivalent to:

```ruby
Accounting::ChartOfAccounts.ensure_for(user)
```

It must be idempotent.

Calling it repeatedly should:

```text
create missing system accounts
leave existing correct accounts alone
never create duplicates
```

If an existing account has the expected key but the **wrong account type**, fail loudly. Do not silently mutate accounting identity.

A changed display name is not an integrity problem.

Because Yanushi currently has no centralized public user-registration resource in its routes, use a narrow `User` creation callback to establish this invariant:

```text
after_create -> ensure chart of accounts
```

Use the callback inside the user creation transaction, not `after_create_commit`, so failure to provision the required accounting foundation also fails creation of the user.

Keep the actual logic in `Accounting::ChartOfAccounts`; the callback should only invoke it.

Also update `db/seeds.rb` to call `ensure_for(user)` explicitly after finding or creating the development user, so running seeds repairs an older development database idempotently. The current seed can reuse an already-existing user. 

---

# 8. Add User associations

Update `User`:

```ruby
has_many :accounts, dependent: :restrict_with_error
has_many :journal_entries, dependent: :restrict_with_error
```

Do not cascade-delete accounting records.

A user with accounting history is no longer something the ORM should casually erase.

---

# 9. Create `journal_entries`

Schema:

```text
journal_entries

id
user_id            NOT NULL

source_type         NOT NULL
source_id           NOT NULL
event_type          NOT NULL

occurred_on         NOT NULL
description

posted_at           NOT NULL

reversal_of_id      NULL

created_at          NOT NULL
```

Do **not** add `updated_at`.

Journal entries are immutable.

Add:

```text
FK user_id -> users
FK reversal_of_id -> journal_entries

index(user_id)
index(occurred_on)

unique index(
  user_id,
  source_type,
  source_id,
  event_type
)

unique partial index(reversal_of_id)
WHERE reversal_of_id IS NOT NULL
```

Use a clearly named source-event unique index, for example:

```text
idx_journal_entries_source_event
```

Add a check:

```text
source_id > 0
```

if all Yanushi source events use ordinary positive Active Record IDs.

---

# 10. Do not make `source` a Rails polymorphic association yet

Store:

```text
source_type
source_id
```

as durable source identity, but do not initially declare:

```ruby
belongs_to :source, polymorphic: true
```

There is no database FK behind a polymorphic association, and later source lifecycle behavior should be explicit on the actual domain models.

The posting service should derive:

```text
source_type = source.class.base_class.name
source_id   = source.id
```

when given a source object.

A reversal uses:

```text
source_type: JournalEntry
source_id: original entry ID
event_type: reversal
```

This preserves generic audit identity without pretending the database has referential integrity it does not actually possess.

---

# 11. Implement `JournalEntry`

Create:

```text
app/models/journal_entry.rb
```

Associations:

```ruby
belongs_to :user

has_many :postings,
  dependent: :restrict_with_error

belongs_to :reversal_of,
  class_name: "JournalEntry",
  optional: true

has_one :reversal,
  class_name: "JournalEntry",
  foreign_key: :reversal_of_id
```

Validate presence of:

```text
user
source_type
source_id
event_type
occurred_on
posted_at
```

Do **not** attempt to validate cross-row balance in this model.

That invariant belongs to the posting boundary where all posting lines are known together.

Convenience methods may include:

```text
reversed?
reversal?
```

derived from associations rather than persisted booleans.

Do not add:

```text
status
draft
balanced
reversed_at
```

Those create redundant state.

---

# 12. Create `postings`

Schema:

```text
postings

id
journal_entry_id      NOT NULL
account_id            NOT NULL
amount_cents          BIGINT NOT NULL

property_id            NULL
rentable_unit_id       NULL
tenancy_id             NULL
party_id               NULL

memo                    NULL

created_at             NOT NULL
```

Again, no `updated_at`.

Add foreign keys to:

```text
journal_entries
accounts
properties
rentable_units
tenancies
parties
```

Add indexes:

```text
journal_entry_id
account_id
property_id
rentable_unit_id
tenancy_id
party_id

(account_id, property_id)
(account_id, tenancy_id)
```

Do not over-index every possible dimension combination yet. Later real query shapes can justify additional composite indexes.

Add a database check:

```text
amount_cents <> 0
```

---

# 13. Implement `Posting`

Create:

```text
app/models/posting.rb
```

Associations:

```ruby
belongs_to :journal_entry
belongs_to :account

belongs_to :property, optional: true
belongs_to :rentable_unit, optional: true
belongs_to :tenancy, optional: true
belongs_to :party, optional: true
```

Validate:

```text
amount_cents != 0
amount_cents is an integer

account belongs to journal_entry.user

all supplied dimensions belong to journal_entry.user
```

Do not impose normal-balance rules such as:

```text
asset account must have positive amount
income must have negative amount
```

Either side of an account can legitimately be posted.

---

# 14. Canonical dimension rules

Implement dimension normalization in the accounting builder.

### Property only

Valid:

```text
property = P
```

Persist:

```text
property_id = P.id
```

### Rentable unit

Caller may supply:

```text
rentable_unit = U
```

Builder derives:

```text
property = U.property
```

Persist both.

### Tenancy

Caller may supply:

```text
tenancy = T
```

Builder derives:

```text
rentable_unit = T.rentable_unit
property = T.rentable_unit.property
```

Persist all three.

### Party

`party` is independent.

A payer can be a party without being a tenancy participant, so do **not** require:

```text
party belongs to tenancy
```

Require only that the party belongs to the same user.

### Contradictions

If the caller supplies:

```text
tenancy: tenancy_a
property: property_b
```

and they disagree, reject the posting specification.

Never silently let explicitly contradictory data be overwritten by inferred values.

---

# 15. Add dimension lifecycle associations

Add accounting-history restrictions to Milestone 1 models.

For example:

```ruby
Property
  has_many :accounting_postings,
    class_name: "Posting",
    dependent: :restrict_with_error
```

Do the same for:

```text
RentableUnit
Tenancy
Party
```

This is important even before normal application events begin posting. Once the ledger references a domain identity, that identity must not be hard-deleted.

`Property` already restricts deletion when expenses exist, and `Tenancy` restricts deletion when legacy financial records exist. Extend that lifecycle protection to accounting postings rather than introducing another path around it. 

Update any existing `financial_history?` helpers so ledger postings count as financial history.

---

# 16. Enforce JournalEntry and Posting immutability

Use one consistent mechanism for both models.

After persistence:

```text
update -> raise/prevent
destroy -> raise/prevent
touch -> prevent
```

This should apply even if the change appears harmless.

Do not make fields such as:

```text
description
memo
occurred_on
```

editable after posting.

Test:

```ruby
entry.update!(description: "changed")
```

fails.

Test:

```ruby
entry.destroy!
```

fails.

Test the same for a posting.

The application-level protection does not need to defend against deliberately bypassing Active Record with raw SQL or `update_columns`; normal Yanushi application code is the threat boundary for this milestone.

---

# 17. Create `Accounting::PostingSpec`

Do not make the central posting API accept arbitrary hashes throughout the codebase.

Create a small typed value object:

```text
app/services/accounting/posting_spec.rb
```

Conceptually:

```ruby
Accounting::PostingSpec.new(
  account_key:,
  amount_cents:,
  property: nil,
  rentable_unit: nil,
  tenancy: nil,
  party: nil,
  memo: nil
)
```

Its job is to describe one requested line before account resolution and dimension normalization.

Keep it persistence-free.

Add an RBS signature.

---

# 18. Create `Accounting::PostingBuilder`

Create:

```text
app/services/accounting/posting_builder.rb
```

Input:

```text
user
Array<PostingSpec>
```

Output should be normalized posting attributes ready for persistence.

Responsibilities:

1. Require at least two posting specs.
2. Require each amount to be nonzero integer cents.
3. Sum all amounts and require exactly zero.
4. Resolve each `account_key` through the supplied user's accounts.
5. Reject an unknown account key.
6. Reject an inactive account.
7. Normalize dimensions.
8. Validate ownership.
9. Reject contradictory dimensions.
10. Produce deterministic normalized posting attributes.

It must **not persist anything**.

Example:

```ruby
specs = [
  Accounting::PostingSpec.new(
    account_key: "tenant_receivable",
    amount_cents: 200_000,
    tenancy: tenancy
  ),
  Accounting::PostingSpec.new(
    account_key: "rental_income",
    amount_cents: -200_000,
    tenancy: tenancy
  )
]
```

Both resulting postings should contain:

```text
property_id
rentable_unit_id
tenancy_id
```

derived from the tenancy.

No Milestone 2 production code should actually post that rent event; this is only the low-level shape later poster services will use.

---

# 19. `PostingBuilder` failure semantics

Follow the repository's existing `ServiceResult` convention rather than adding a second service-result framework. `ServiceResult` already provides structured `Success`/`Failure` values with `data`, `error`, and `code`. 

Useful failure codes include:

```text
:invalid_postings
:unbalanced_entry
:missing_account
:inactive_account
:ownership_mismatch
:dimension_mismatch
```

The exact list can be smaller if several conditions naturally map to one validation code.

Failures must occur before persistence.

---

# 20. Create `Accounting::PostEntryService`

Create:

```text
app/services/accounting/post_entry_service.rb
```

Suggested API:

```ruby
Accounting::PostEntryService.call(
  user:,
  source:,
  event_type:,
  occurred_on:,
  description: nil,
  postings:
)
```

where:

```text
source is a persisted ApplicationRecord
postings is Array<Accounting::PostingSpec>
```

Responsibilities:

1. Reject an unpersisted source.
2. Derive the source identity.
3. Normalize description/event type.
4. Call `PostingBuilder`.
5. Check whether the source event was already posted.
6. Validate an existing entry against the requested event if found.
7. If no existing entry exists, atomically create:
   - `JournalEntry`
   - every `Posting`
8. Set:
   ```text
   posted_at = Time.current
   ```
9. Return the journal entry.

Do not expose this service through a controller or route.

---

# 21. Make idempotency stronger than `find-or-return`

A naïve implementation like:

```ruby
existing = JournalEntry.find_by(source identity)
return existing if existing
```

is insufficient.

Suppose a buggy retry uses the same source identity but asks for:

```text
first invocation:  $2,000
second invocation: $2,100
```

Returning the first entry would hide an accounting inconsistency.

When the source-event identity already exists, compare the requested normalized entry against the persisted entry.

Compare at least:

```text
occurred_on
normalized description
posting count

for every posting:
  account
  amount_cents
  property
  rentable_unit
  tenancy
  party
  memo
```

Sort posting representations canonically before comparison so line ordering doesn't matter.

If identical:

```text
return existing journal entry successfully
```

If different:

```text
fail with :idempotency_conflict
```

This makes retries safe without hiding changes in financial effect.

---

# 22. Protect idempotency under concurrency

The unique database index is the final arbiter.

Use this flow:

```text
1. check existing
2. attempt transactional create
3. if unique constraint loses a race:
     leave failed transaction
     reload existing entry outside it
     compare requested content
     return existing if equal
     otherwise idempotency conflict
```

Do not rescue `RecordNotUnique` and then query inside the same aborted PostgreSQL transaction.

Add a concurrency spec if practical.

Two concurrent invocations for the same source event must result in:

```text
1 JournalEntry
N Postings
```

not two entries.

---

# 23. Atomic persistence

`PostEntryService` should persist one entry using one database transaction:

```text
BEGIN

create journal entry
create posting 1
create posting 2
...
validate expected posting count

COMMIT
```

If any posting fails:

```text
ROLLBACK everything
```

Test a case where one posting is invalid after another line could otherwise have been created.

After the failure:

```text
JournalEntry count unchanged
Posting count unchanged
```

---

# 24. Prevent partial construction through nested AR behavior

Do not rely on:

```ruby
journal_entry.save!
# then later...
posting.save!
```

across multiple transactions.

Do not expose a public workflow that creates a `JournalEntry` and lets the caller append postings later.

`JournalEntry` has no meaningful persisted state without its complete postings.

The internal service boundary is:

```text
PostingSpec[] -> complete immutable JournalEntry
```

---

# 25. Create `Accounting::ReverseEntryService`

Create:

```text
app/services/accounting/reverse_entry_service.rb
```

Suggested API:

```ruby
Accounting::ReverseEntryService.call(
  journal_entry:,
  occurred_on:,
  description: nil
)
```

Make `occurred_on` explicit.

Do not silently assume that a correction always belongs on today's accounting date.

---

# 26. Reversal behavior

Inside a transaction:

1. Lock the original journal entry.
2. Reject attempting to reverse an entry that is itself a reversal for MVP.
3. Check whether a reversal already exists.
4. If it exists, return it idempotently.
5. For every original posting create:
   ```text
   same account
   same dimensions
   same memo
   amount_cents * -1
   ```
6. Create the reversal journal entry with:
   ```text
   source_type: "JournalEntry"
   source_id: original.id
   event_type: "reversal"
   reversal_of_id: original.id
   ```
7. Persist atomically.
8. Return the new entry.

Example:

```text
Original

Tenant Receivable       +200000
Rental Income           -200000

Reversal

Tenant Receivable       -200000
Rental Income           +200000
```

Do not modify the original row.

---

# 27. Only one reversal per entry

Use both:

```text
application validation/service check
```

and:

```text
unique DB index on reversal_of_id
```

to ensure an original entry cannot acquire two reversal entries.

Two simultaneous reversal requests should either:

```text
one creates reversal
other returns same reversal
```

or otherwise resolve idempotently.

They must not create two offsetting entries.

---

# 28. Do not support reversal-of-reversal yet

For this milestone:

```text
entry.reversal_of_id.present?
```

means it cannot itself be passed to `ReverseEntryService`.

If a future correction needs to reinstate a reversed transaction, the domain should create a new source event and post it.

This keeps the audit graph simple:

```text
source event
  -> original journal entry
       -> one reversal
```

rather than arbitrarily nested reversal chains.

---

# 29. Update factories

Add:

```text
:account
:journal_entry
:posting
```

Be careful with `:user`.

If user creation now provisions system accounts automatically, an `:account` factory using a standard system key may collide with provisioning.

Use an explicitly non-system factory key by default, e.g.:

```text
test_asset_1
```

or define traits that reuse a provisioned system account instead of attempting to recreate it.

Prefer helpers such as:

```ruby
user.accounts.find_by!(key: "cash")
```

in accounting service specs.

Do not manually create journal entries/postings in most specs. Exercise `PostEntryService`.

Direct model construction should be limited to model-validation/immutability tests.

---

# 30. Update seeds

After locating/creating the development user:

```ruby
Accounting::ChartOfAccounts.ensure_for(user)
```

The existing legacy seed financial activity should remain legacy for this milestone. It currently creates `ScheduledRent`, `TenantPayment`, and `Expense` rows directly; do not add corresponding journal entries yet. 

That separation is important.

Otherwise Milestone 2 would accidentally become a partial migration where seed data behaves differently from production application paths.

---

# 31. Do not alter existing financial queries

Leave these kinds of queries alone:

```text
Properties::FinancialItemsQuery
Properties::ScheduleESummaryQuery
Tenancies::BalanceQuery
```

They should continue reading the legacy financial models for now.

`Tenancy#current_balance` currently delegates to the legacy tenancy balance query. Keep that behavior until the milestone that explicitly replaces tenant balance with Tenant Receivable postings. 

Do not make some balances ledger-backed while others remain legacy-backed.

---

# 32. Do not add accounting UI

No:

```text
AccountsController
JournalEntriesController
PostingsController
/accounting routes
journal-entry editor
manual journal entry form
```

Milestone 2 is infrastructure.

Normal users should see no behavioral difference.

Developer-level model/service inspection is sufficient.

---

# 33. Model test matrix: Account

Add tests proving:

- [ ] Account belongs to user.
- [ ] `key` is required.
- [ ] `name` is required.
- [ ] Valid account types are accepted.
- [ ] Invalid account types become validation errors.
- [ ] Account key is unique per user.
- [ ] Same account key may exist for another user.
- [ ] Key is normalized.
- [ ] `user_id` cannot change after creation.
- [ ] `key` cannot change after creation.
- [ ] `account_type` cannot change after creation.
- [ ] `name` may change.
- [ ] `active` may change.
- [ ] Account with postings cannot be destroyed.

---

# 34. Service test matrix: Chart of Accounts

Test:

- [ ] New user receives all system accounts.
- [ ] Every required key has correct account type.
- [ ] Calling `ensure_for` twice creates no duplicates.
- [ ] Missing system account is restored.
- [ ] Existing key with wrong account type causes failure.
- [ ] Same chart is provisioned independently for two users.
- [ ] Failed chart provisioning rolls back user creation.

Do not assert account IDs or creation order.

Keys are the stable identity.

---

# 35. Model test matrix: JournalEntry

Test:

- [ ] Requires user.
- [ ] Requires source type.
- [ ] Requires positive source ID.
- [ ] Requires event type.
- [ ] Requires occurred date.
- [ ] Requires posted time.
- [ ] Source-event tuple is unique.
- [ ] Cannot update persisted entry.
- [ ] Cannot destroy persisted entry.
- [ ] Can identify its reversal.
- [ ] Can identify that it is itself a reversal.
- [ ] Only one reversal may reference an original entry.

Do not pretend a model spec alone proves balancing.

---

# 36. Model test matrix: Posting

Test:

- [ ] Requires journal entry.
- [ ] Requires account.
- [ ] Requires nonzero integer amount.
- [ ] Positive amount is allowed.
- [ ] Negative amount is allowed.
- [ ] Zero is rejected at model and DB levels.
- [ ] Optional dimensions are permitted.
- [ ] Account must belong to journal-entry user.
- [ ] Property must belong to journal-entry user.
- [ ] Unit must belong to journal-entry user's property.
- [ ] Tenancy hierarchy must be coherent.
- [ ] Party must belong to journal-entry user.
- [ ] Party need not be a participant in the tenancy.
- [ ] Persisted posting cannot update.
- [ ] Persisted posting cannot destroy.

---

# 37. `PostingBuilder` test matrix

Test at least:

### Balanced entry

```text
+200000
-200000
= 0
```

succeeds.

### Unbalanced

```text
+200000
-199999
= 1
```

fails.

### One line

```text
0 total is impossible with nonzero one-line entry
```

but explicitly test the two-line minimum.

### Zero posting

Reject.

### Missing account

Reject.

### Inactive account

Reject.

### Other user's account

Impossible through key resolution; explicitly prove the builder resolves only against supplied user.

### Tenancy dimension derivation

Given only:

```text
tenancy
```

output includes:

```text
property
rentable_unit
tenancy
```

### Contradictory property

Reject.

### Contradictory unit

Reject.

### Cross-user party

Reject.

---

# 38. `PostEntryService` test matrix

Use a persisted existing model as a harmless test source, but do **not** connect that model's lifecycle to posting.

For example an `Expense` fixture may act as the source identity solely within service specs.

Test:

- [ ] Balanced specifications create one entry and all postings.
- [ ] `posted_at` is set.
- [ ] Source type and ID are persisted.
- [ ] Event type is persisted.
- [ ] `occurred_on` is preserved.
- [ ] Description is preserved.
- [ ] Repeating the exact call returns the same entry.
- [ ] Exact retry creates no additional postings.
- [ ] Same source identity with changed amount fails `idempotency_conflict`.
- [ ] Same source identity with changed account fails.
- [ ] Same source identity with changed dimensions fails.
- [ ] Same source identity with changed occurred date fails.
- [ ] Invalid posting produces no journal entry.
- [ ] One invalid line rolls the entire operation back.
- [ ] Other user's dimensions fail.
- [ ] Missing/inactive accounts fail normally.

---

# 39. Add a concurrency idempotency test

Use two independent database connections/threads if the existing test setup supports it reliably.

Run the same `PostEntryService` event concurrently.

Assert:

```text
JournalEntry.where(source identity).count == 1
```

and that its postings exist exactly once.

If thread-based database concurrency is too flaky for the test environment, at minimum test the `RecordNotUnique` recovery branch explicitly.

Do not leave the race recovery untested merely because the happy-path uniqueness spec passes.

---

# 40. `ReverseEntryService` test matrix

Test:

- [ ] Original entry remains unchanged.
- [ ] Reversal has `reversal_of_id`.
- [ ] Reversal source identity references original journal entry.
- [ ] Every amount is negated exactly.
- [ ] Accounts are identical.
- [ ] Property dimensions are identical.
- [ ] Unit dimensions are identical.
- [ ] Tenancy dimensions are identical.
- [ ] Party dimensions are identical.
- [ ] Memos are retained.
- [ ] Reversal is balanced.
- [ ] Explicit reversal `occurred_on` is used.
- [ ] Calling reversal twice returns one reversal.
- [ ] Reversal-of-reversal is rejected.
- [ ] Concurrent reversal attempts cannot produce two reversals.

---

# 41. Add global accounting invariant tests

Create a shared matcher/helper or focused spec that asserts for every created journal entry in the accounting service suite:

```ruby
entry.postings.sum(:amount_cents) == 0
```

Also verify:

```text
entry.postings.count >= 2
```

Consider a generated test over dozens or hundreds of randomly-sized balanced posting sets:

```text
random debits
random credits
final balancing line
```

Every accepted set must persist with sum zero.

Mutating one amount by one cent must cause rejection.

The important property is the invariant, not any one example.

---

# 42. Add database-constraint tests

Application validation is not enough for the simple invariants the database can enforce.

Test direct SQL/validation bypass where useful for:

```text
accounts.account_type constraint
postings.amount_cents <> 0
journal_entries source-event uniqueness
journal_entries reversal_of uniqueness
foreign keys
```

You do **not** need a database trigger to enforce cross-row balancing in this milestone.

Keep that invariant at the posting service boundary as the PRD intended.

---

# 43. Locking rules

Document one accounting lock policy.

### Ordinary posting

No account lock is needed.

Source-specific services added in later milestones should lock their domain source before invoking accounting posting.

For Milestone 2, source-event uniqueness protects the generic posting service.

### Reversal

Lock:

```text
original JournalEntry
```

before checking/creating its reversal.

### Chart provisioning

Unique `(user_id, key)` is the final protection.

Do not introduce broad user/account locks unless a concurrency test demonstrates a need.

---

# 44. Error handling

Do not rescue every exception into `ServiceResult`.

Expected input/business failures should return normal failures:

```text
unbalanced
invalid dimension
missing account
inactive account
idempotency conflict
already reversed / invalid reversal
```

Unexpected persistence/invariant failures should propagate or otherwise fail loudly.

In particular:

```text
"somehow produced an unbalanced persisted specification"
```

is a programming error, not a friendly validation state.

---

# 45. Update `financial_history?`

Milestone 1 currently treats surviving financial records as financial history when deciding whether tenancy deletion is permissible. 

Extend this concept.

For `Tenancy`:

```text
financial_history?
=
legacy financial history
OR accounting_postings.exists?
```

For `Property`, its existing deletion restrictions plus accounting-posting association should prevent deletion once ledger history references it.

For `RentableUnit` and `Party`, accounting postings should similarly protect referenced identities.

Do not add duplicated boolean `has_accounting_history`.

Derive it.

---

# 46. Keep source deletion concerns deferred to source integration

Milestone 2 knows only that a journal entry has:

```text
source_type
source_id
```

It does not yet need to modify every legacy financial model to restrict deletion because none of those models automatically posts yet.

When `Charge`, `Receipt`, `Expense`, and security-deposit events acquire journal entries in their respective milestones, each source model must then restrict destruction once posted.

Do not prematurely wire legacy `TenantPayment` or `Expense` deletion to journal entries merely because accounting specs use one as a test source.

---

# 47. Update RBS

Add hand-written signatures under `sig/app` for:

```text
Account
JournalEntry
Posting

Accounting::ChartOfAccounts
Accounting::PostingSpec
Accounting::PostingBuilder
Accounting::PostEntryService
Accounting::ReverseEntryService
```

Update signatures for:

```text
User
Property
RentableUnit
Tenancy
Party
```

to include accounting associations where those classes are typed.

Add new application files to the `Steepfile` check list as appropriate.

The repository requires regenerating Rails signatures after schema changes. 

Run:

```bash
bin/rails rbs_rails:all
bundle exec rbs validate
bundle exec steep check
```

Do not hand-edit generated `sig/rbs_rails` output.

---

# 48. Update documentation

Add:

```text
documentation/accounting_architecture.md
```

Document:

## Signed posting convention

```text
positive = debit
negative = credit
```

## Balance rule

```text
sum(postings.amount_cents) == 0
```

## Account ownership

```text
Account -> User
```

## Dimensions

```text
Property
RentableUnit
Tenancy
Party
```

are dimensions, not accounts.

## Canonical dimensional derivation

```text
Tenancy -> Unit -> Property
```

## Source-event identity

```text
user + source_type + source_id + event_type
```

## Idempotency

Same identity + same financial event:

```text
return existing
```

Same identity + different content:

```text
error
```

## Immutability

Posted entries never change.

## Reversals

Corrections negate the original without modifying it.

## How future financial events should integrate

Every future poster must answer:

```text
What is the immutable domain source event?

What date is occurred_on?

Which accounts change?

What are the signed amounts?

Which dimensions apply?

What source event/event_type provides idempotency?

What reversal/correction semantics apply?
```

---

# 49. Update README only minimally

Do not rewrite the public README to claim financial reporting is ledger-backed yet.

That would be false until later milestones; the current README still describes the existing scheduled-rent/payment/expense financial experience. 

A short development-facing reference to the accounting architecture document is enough.

---

# 50. Explicitly avoid these changes

Do **not** implement during Milestone 2:

- `Charge`
- `Receipt`
- `SecurityDeposit`
- `SecurityDepositTransaction`
- `PropertyTaxProfile`
- receipt allocations
- rent-charge generation
- expense posting
- payment posting
- security-deposit posting
- tenant-balance migration
- property-ledger migration
- Schedule E migration
- cash-basis tax mapping
- source-document redesign
- arbitrary/manual journal entries
- bank accounts or reconciliation
- custom chart-of-accounts UI
- accounting controller/routes
- cached account balances
- opening-balance workflow

Most importantly:

```text
do not dual-write legacy models into the ledger
```

Milestone 2 is complete infrastructure, not partial adoption.

---

# 51. Suggested implementation order

I would have an agent perform the work in this order:

### Phase A: schema and primitive models

1. Add accounting migration.
2. Add `Account`.
3. Add `JournalEntry`.
4. Add `Posting`.
5. Add associations to `User` and dimension models.
6. Regenerate schema.
7. Add basic model specs.

Get this green before building services.

### Phase B: chart of accounts

8. Add `Accounting::ChartOfAccounts`.
9. Add user provisioning.
10. Update seeds.
11. Add provisioning specs.

### Phase C: posting construction

12. Add `Accounting::PostingSpec`.
13. Add `Accounting::PostingBuilder`.
14. Implement dimension normalization.
15. Implement balancing.
16. Add builder tests.

### Phase D: persistence/idempotency

17. Add `Accounting::PostEntryService`.
18. Add atomic transaction.
19. Add source-event uniqueness recovery.
20. Add existing-entry equivalence comparison.
21. Add atomicity and idempotency tests.
22. Add concurrency coverage.

### Phase E: reversals/immutability

23. Enforce journal/posting immutability.
24. Add `Accounting::ReverseEntryService`.
25. Add single-reversal protection.
26. Add reversal tests.

### Phase F: integration hygiene

27. Extend financial-history deletion protection.
28. Update RBS.
29. Update Steep configuration.
30. Add accounting architecture documentation.
31. Run full quality suite.
32. Search for accidental ledger integration with legacy financial events.

---

# 52. Search before finalizing

Run:

```bash
rg -n \
  'JournalEntry|Posting|PostEntry|PostingBuilder|account_key|amount_cents' \
  app
```

Review every hit.

Expected production callers at this milestone should be limited to accounting infrastructure and model associations.

There should **not** yet be code like:

```text
TenantPayment -> PostEntryService
Expense -> PostEntryService
ScheduledRent -> PostEntryService
TenantCharge -> PostEntryService
PaymentIngestion -> PostEntryService
```

If such integrations appear, remove them and defer them to their proper milestone.

---

# 53. Verify no raw posting creation leaks out

Run:

```bash
rg -n \
  'Posting\.(create|create!|new)|postings\.(create|create!|build)|JournalEntry\.(create|create!|new)' \
  app
```

Outside:

```text
Accounting::PostEntryService
Accounting::ReverseEntryService
```

there should be no production code directly persisting journal entries or postings.

Model specs may do so when explicitly testing model constraints.

This is an important architectural acceptance criterion.

---

# 54. Clean database verification

Run:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate
```

Then:

```bash
bin/rails runner '
  user = User.create!(
    email: "accounting-test@example.com",
    password: "password123"
  )

  puts user.accounts.order(:key).pluck(:key, :account_type)
'
```

Verify every defined system account exists exactly once.

Then exercise a development-only runner example:

```text
build a balanced two-line event
post it
post it again
verify same JournalEntry ID
reverse it
verify aggregate sum across original + reversal = 0
```

Do not add that example as application functionality.

---

# 55. Final quality gate

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

Verify line coverage remains:

```text
>= 95%
```

which is the current CI requirement. 

---

# 56. Suggested commit boundaries

### Commit 1: Add accounting schema and models

```text
Account
JournalEntry
Posting
database constraints
associations
immutability
model specs
```

### Commit 2: Provision the chart of accounts

```text
Accounting::ChartOfAccounts
User provisioning
seeds
account provisioning specs
```

### Commit 3: Add balanced posting infrastructure

```text
PostingSpec
PostingBuilder
dimension normalization
ownership checks
balance validation
builder specs
```

### Commit 4: Add atomic idempotent posting

```text
PostEntryService
source-event uniqueness
conflict detection
transaction rollback
concurrency behavior
specs
```

### Commit 5: Add reversals

```text
ReverseEntryService
single-reversal semantics
reversal concurrency
specs
```

### Commit 6: Finish integration and documentation

```text
financial-history restrictions
RBS
Steep
generated Rails signatures
accounting architecture docs
cleanup
```

Each commit should ideally leave the suite green.

---

# 57. Milestone 2 acceptance checklist

## Schema

- [ ] `accounts` exists.
- [ ] `journal_entries` exists.
- [ ] `postings` exists.
- [ ] All accounting money is bigint cents.
- [ ] Posting zero amounts are DB-rejected.
- [ ] Source-event identity is uniquely indexed.
- [ ] `reversal_of_id` permits at most one reversal.
- [ ] Dimension foreign keys exist.

## Accounts

- [ ] Accounts belong to users.
- [ ] System chart is centrally defined.
- [ ] Every newly-created user receives the chart.
- [ ] Provisioning is idempotent.
- [ ] Stable keys cannot change.
- [ ] Account types cannot change.
- [ ] Used accounts cannot be deleted.
- [ ] No account-management UI exists.

## Posting construction

- [ ] Posting specs are typed value objects.
- [ ] Unknown account keys fail.
- [ ] Inactive accounts fail.
- [ ] Every accepted entry contains at least two lines.
- [ ] Every accepted entry sums exactly to zero.
- [ ] Zero lines fail.
- [ ] Cross-user dimensions fail.
- [ ] Tenancy automatically derives unit/property dimensions.
- [ ] Explicitly contradictory dimensions fail.

## Persistence

- [ ] Entry and all postings persist in one transaction.
- [ ] Any line failure rolls the whole operation back.
- [ ] Exact retry returns the existing entry.
- [ ] Exact retry creates no duplicate postings.
- [ ] Conflicting retry fails as an idempotency conflict.
- [ ] Concurrent identical posting cannot duplicate the entry.

## Immutability

- [ ] Journal entries cannot be updated.
- [ ] Journal entries cannot be destroyed.
- [ ] Postings cannot be updated.
- [ ] Postings cannot be destroyed.
- [ ] Dimension records referenced by postings cannot be casually deleted.

## Reversals

- [ ] Reversal creates a new journal entry.
- [ ] Original remains unchanged.
- [ ] Every reversal posting is the exact negation of its original.
- [ ] Dimensions remain identical.
- [ ] Reversal balances.
- [ ] One original can have at most one reversal.
- [ ] Repeated reversal requests are idempotent.
- [ ] Reversal-of-reversal is rejected for MVP.

## Boundaries

- [ ] `TenantPayment` does not post.
- [ ] `TenantCharge` does not post.
- [ ] `ScheduledRent` does not post.
- [ ] `Expense` does not post.
- [ ] Payment ingestion does not post.
- [ ] Tenant balance is still legacy-backed.
- [ ] Property financial ledger is still legacy-backed.
- [ ] Schedule E is still legacy-backed.
- [ ] No accounting UI/routes were added.
- [ ] No production code outside the accounting services directly creates postings/journal entries.

## Quality

- [ ] Model specs pass.
- [ ] Posting-builder specs pass.
- [ ] Idempotency specs pass.
- [ ] Atomicity specs pass.
- [ ] Concurrency behavior is covered.
- [ ] Reversal specs pass.
- [ ] RBS validates.
- [ ] Steep passes.
- [ ] RuboCop passes.
- [ ] RSpec passes.
- [ ] Coverage remains ≥95%.
- [ ] Security scans pass.
- [ ] Accounting architecture documentation exists.

---

# 58. Desired end state

At the end of Milestone 2, this should work internally:

```text
Source event X
    │
    ▼
Accounting::PostEntryService
    │
    ├── validates source-event identity
    ├── resolves system accounts
    ├── normalizes dimensions
    ├── verifies ownership
    ├── verifies sum == 0
    ├── detects idempotent retry/conflict
    │
    ▼
JournalEntry
├── Posting +200000 Tenant Receivable
│   ├── Property
│   ├── RentableUnit
│   └── Tenancy
│
└── Posting -200000 Rental Income
    ├── Property
    ├── RentableUnit
    └── Tenancy
```

And:

```text
Accounting::ReverseEntryService
       │
       ▼

new immutable JournalEntry
with exact opposite postings
```

But the actual application should still look and behave exactly as it did before Milestone 2.

That is the key acceptance boundary: **Milestone 2 proves that Yanushi has a trustworthy accounting substrate. Milestone 3 is the first milestone that should begin moving actual rental-domain financial truth onto it.**
