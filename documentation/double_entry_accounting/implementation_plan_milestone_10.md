## Milestone 10 implementation plan

### 1. Establish the cleanup inventory

Before deleting anything, run a repository-wide audit for the identifiers replaced by the project:

```text
RentalProperty
Lease
LeaseTenant
TenantAlias
ScheduledRent
TenantPayment
TenantCharge
PaymentDocument
PaymentIngestion
PaymentReceiptIngestion

rental_properties
leases
lease_tenants
tenant_aliases
scheduled_rents
tenant_payments
tenant_charges
payment_documents
payment_ingestions
```

Do this separately across:

```text
app/
config/
lib/
spec/
sig/
db/schema.rb
db/seeds.rb
README.md
documentation/
```

Classify every match as one of:

1. **obsolete executable code** → delete/update;
2. **obsolete test/type artifact** → delete/update;
3. **stale user-facing terminology** → rewrite;
4. **historical migration** → normally retain;
5. **historical implementation-plan text** → delete if superseded, otherwise explicitly mark historical;
6. **legitimate domain language** → retain.

That distinction matters. For example, the phrase “tenant receivable” remains part of the new accounting vocabulary; an actual `TenantPayment` constant does not.

I would make the inventory itself the first commit or at least record it in the Milestone 10 implementation-plan document, because the milestone's success criterion is effectively “the old architecture is gone.”

### 2. Remove runtime compatibility remnants

Delete any surviving models, queries, services, controllers, routes, helpers, or views found by the inventory **only after confirming they have no live callers**.

I expect this phase to be quite small. The current top-level model directory already contains only the new domain/accounting models, the controller tree likewise uses the new resources, and the route set exposes properties, parties, tenancies, receipts, charges, deposits, ledger entries, and ingestion under their new names. 

So the rule should be:

> Don't refactor working M1–M9 code during M10 merely because this is a “cleanup” milestone.

This milestone should remove dead compatibility surfaces, not reorganize the new architecture.

### 3. Finish schema cleanup

The current schema already has no `rental_properties`, `leases`, `scheduled_rents`, `tenant_payments`, or `tenant_charges` tables, so **do not add another drop migration just to satisfy the PRD wording**. Those tables have already been removed by earlier milestone migrations. 

There is at least one genuine piece of stale schema metadata worth cleaning: the `party_aliases` table still has an index named:

```text
index_tenant_aliases_on_tenant_id_and_lower_alias_name
```

despite now indexing `party_id`. 

Add a tiny migration:

```ruby
rename_index(
  :party_aliases,
  "index_tenant_aliases_on_tenant_id_and_lower_alias_name",
  "index_party_aliases_on_party_id_and_lower_alias_name"
)
```

Then regenerate `db/schema.rb`.

I **would not squash the old migrations as part of M10**. The migration directory naturally records the path from the old schema through the cutover, including the old table creation and later drop migrations.  The PRD permits destructive replacement because there is no production data, but migration-history squashing has a different risk/reward profile and doesn't make the running application cleaner. If you eventually want a pristine baseline migration, I would do that separately after this project lands.

### 4. Delete superseded design documentation

There are two especially clear candidates:

```text
documentation/running_account_refactor/implementation_plan.md
documentation/payment_ingestion/implementation_plan.md
```

The running-account document still describes `Lease`, `ScheduledRent`, `TenantPayment`, `TenantCharge`, `RentalProperty`, and the old pre-double-entry balance model as if they were the architecture.  Those concepts have now been superseded wholesale.

The old payment-ingestion plan is similarly predecessor documentation; Milestone 7 replaced that architecture with `SourceDocument` / `ImportedTransaction` and confirmation into `Receipt` or `SecurityDepositTransaction`. 

I would delete those two directories rather than “update” them. Git contains their history if it is ever useful.

I would **retain**:

```text
documentation/double_entry_accounting/prd.md
documentation/double_entry_accounting/implementation_plan_milestone_1.md
...
implementation_plan_milestone_9.md
```

Those form the design history of the project itself rather than describing a competing architecture. The directory currently contains all nine milestone plans plus the PRD. 

Add `implementation_plan_milestone_10.md` as the final project record.

### 5. Replace the milestone-specific architecture document with the final architecture

`documentation/accounting_architecture.md` is currently titled **“Double-Entry Accounting Engine Architecture (Milestone 2)”** and mostly documents the accounting foundation—accounts, journals, postings, posting services, and reversal mechanics. 

M10 is the right time to make it the durable architecture document for the finished system.

I would rewrite/extend it to cover the ten subjects the PRD explicitly requires:

1. rental-domain vs accounting boundaries;
2. debit/credit sign convention;
3. chart of accounts;
4. posting rules for Charge, Receipt, Expense, Deposit;
5. source-event idempotency;
6. corrections and reversals;
7. running-account semantics;
8. security-deposit semantics;
9. accounting vs Schedule E/tax-reporting basis;
10. how to add a new financial event safely. 

The last section should be particularly concrete. A new event should require answering:

```text
What domain record is the source?
What event_type does it use?
Which accounts move?
Which posting dimensions are required?
What makes posting idempotent?
How is it reversed?
How does it appear in operational reporting?
Does it have tax-reporting semantics?
Does ingestion need to produce it?
```

That document becomes the place an engineer reads instead of reconstructing the architecture from nine milestone plans.

### 6. Rewrite the README around the finished product

This is a definite M10 task. The README still advertises:

- “Tenant & Lease Management”;
- “automated rent schedules”;
- a “Unified Financial Ledger” composed of `Scheduled Rent`, `Tenant Payment`, `Expense`, and `Tenant Charge`;
- matching imports against active leases;
- payments zeroing out scheduled rent;
- manually recording a payment against an individual scheduled rent. 

Those are now materially wrong.

Rewrite the feature/usage sections around:

```text
Property / Rentable Unit
Party / Tenancy
RentTerm
Charge
Receipt
Expense
SecurityDeposit
SourceDocument / ImportedTransaction
JournalEntry / Posting
Schedule E projection
```

The README doesn't need to teach debit/credit accounting—that belongs in `accounting_architecture.md`—but it should stop presenting the deleted architecture as the product.

I'd also update or remove screenshots whose UI no longer matches the current application rather than retaining captions describing obsolete interactions.

### 7. Clean specs and factories only where they represent removed surfaces

The model spec tree is already entirely on the replacement model set, and the central factory file likewise uses the new models. 

So this should **not** be a broad test rewrite.

Audit the request, system, feature, service, and query specs for:

- old path/helper names;
- old UI labels;
- obsolete compatibility tests;
- stale comments referring to leases/payments/scheduled rents as persisted objects.

Delete tests only when the production surface they tested has genuinely been deleted.

Most importantly, **retain the invariant-heavy M2–M9 tests**. They are now the safety net that permits cleanup.

### 8. Regenerate Rails RBS last

Do not manually chase generated Rails signatures during earlier cleanup.

The hand-maintained `sig/app/models` directory is already aligned with the current model vocabulary.  After all schema/code deletions and the index rename are complete:

```bash
bin/rails rbs_rails:all
```

Then inspect the diff:

- removed generated signatures should correspond to removed code/schema;
- new changes should correspond to the final schema;
- no legacy generated constants should remain.

Given the concern we discussed earlier about RBS becoming end-of-cycle churn, this is exactly the place where regeneration belongs: **after the architecture and schema are stable**, not interleaved with cleanup decisions.

Then run:

```bash
bundle exec rbs validate
bundle exec steep check
```

The PRD explicitly requires both. 

### 9. Prove clean-database correctness

Because M10 is deleting historical scaffolding, don't only test an already-migrated development DB.

Exercise both Rails-supported fresh-database paths:

```bash
RAILS_ENV=test bin/rails db:drop db:create db:schema:load
bundle exec rspec
```

and, preferably in a disposable database:

```bash
bin/rails db:drop db:create db:migrate
```

The first proves the final schema is self-contained. The second proves retaining the historical migrations still gets from zero to the exact current schema.

Compare the resulting schema after `db:migrate` to the checked-in `db/schema.rb`; unexplained differences are cleanup bugs.

This is especially valuable here because the migration directory still contains the entire old-domain → new-domain sequence. 

### 10. Run the entire quality gate

The PRD names:

```bash
bundle exec rbs validate
bundle exec steep check
bundle exec rspec
```

plus all normal project checks. 

The repository's CI additionally runs:

```bash
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

and enforces **95% line coverage** after RSpec. 

So I would make the final M10 gate:

```bash
bundle exec rbs validate
bundle exec steep check
bundle exec rspec
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

plus fresh-schema and fresh-migration checks.

## Suggested commit sequence

I would keep this to roughly five commits:

1. **`Inventory and remove obsolete runtime artifacts`**  
   Delete only genuinely dead compatibility code/specs/signatures found by the audit.

2. **`Finish double-entry schema cleanup`**  
   Rename stale `party_aliases` index metadata and regenerate schema.

3. **`Remove superseded architecture documentation`**  
   Delete the running-account and old payment-ingestion plans.

4. **`Document the final rental and accounting architecture`**  
   Rewrite `accounting_architecture.md`, README, screenshots/captions as needed, and add `implementation_plan_milestone_10.md`.

5. **`Regenerate Rails signatures after accounting cutover`**  
   Run `rbs_rails:all`, make only necessary hand-written RBS changes, and land the clean final generated state.

Then a final coverage/quality-only commit only if the cleanup exposes legitimate coverage gaps.

## Done when

I would tighten M10's definition of done to this:

- no executable code references a deleted domain model/table/route;
- no obsolete tables exist in `db/schema.rb`;
- the stale `tenant_aliases` schema identifier is gone;
- the README describes the **current** domain and UI;
- superseded predecessor architecture docs are removed;
- `accounting_architecture.md` documents the final M1–M9 system rather than only M2;
- generated RBS reflects the final schema;
- a blank DB can be created both from `schema.rb` and by running migrations;
- all required accounting/invariant scenarios still pass;
- RBS validation, Steep, RSpec, RuboCop, security audits, and the 95% coverage gate are green. 

The important constraint is **M10 should not become “refactor the refactor.”** The architecture is now working and has been through substantial review. This milestone should make the repository tell one coherent story about that architecture and prove nothing from the old story remains load-bearing.
