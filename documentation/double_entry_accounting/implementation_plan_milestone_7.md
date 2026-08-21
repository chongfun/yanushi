# Milestone 7 implementation plan

## 1. Objective

Replace:

```text
PaymentDocument
└── PaymentIngestion
    └── Receipt
```

with:

```text
SourceDocument
└── ImportedTransaction
    └── confirmed_source
        ├── Receipt
        └── SecurityDepositTransaction(received)
```

The final confirmation semantics are:

```text
tenant_receipt
    -> Receipt
    -> Dr Cash
       Cr Tenant Receivable

security_deposit
    -> SecurityDepositTransaction(received)
    -> Dr Cash
       Cr Security Deposits Held
```

An imported transaction itself never posts anything. 

---

## 2. Milestone boundary

Implement:

- `SourceDocument`;
- `ImportedTransaction`;
- generalized parsing/result vocabulary;
- Party/Tenancy matching;
- explicit import transaction classification;
- ordinary Receipt confirmation;
- security-deposit receipt confirmation;
- polymorphic confirmed-source provenance;
- cross-upload duplicate identity;
- concurrent confirmation safety;
- generalized ingestion UI;
- renamed jobs/services/controllers/routes;
- RBS/Steep coverage.

Do **not** implement:

- bank feeds;
- automatic bank reconciliation;
- expense ingestion;
- automated accounting classification beyond the two incoming-money types;
- automatic security-deposit requirement creation;
- OCR/image ingestion expansion;
- transaction allocation;
- Milestone 8 ledger reporting.

Milestone 8 remains the ledger/reporting rewrite. 

---

# 3. Make a clean schema cutover

The PRD explicitly allows direct schema replacement because there is no production data to preserve. There is no reason to carry `PaymentDocument`/`PaymentIngestion` compatibility aliases through subsequent milestones. 

Replace:

```text
payment_documents
payment_ingestions
```

with:

```text
source_documents
imported_transactions
```

I'd make this a real model/table rename plus field cleanup rather than leaving generalized classes backed by payment-named tables.

---

# 4. `SourceDocument`

Target:

```text
source_documents

id
user_id                    NOT NULL
document_type              NOT NULL
attachment_file
attachment_filename
attachment_content_type
status                     NOT NULL
error_message
created_at
updated_at
```

Suggested `document_type`:

```text
unknown
zelle
venmo
chase_statement
```

Suggested status:

```text
processing
success
failed
```

The current `PaymentDocument` already provides the attachment/status/error structure; the missing abstraction is that the document is no longer intrinsically a "payment document." 

Do not migrate the binary attachment implementation to Active Storage as part of this milestone. That's unrelated churn.

---

# 5. `ImportedTransaction`

Target:

```text
imported_transactions

id
user_id                    NOT NULL
source_document_id         NOT NULL

source                     NOT NULL
transaction_kind           NOT NULL

amount_cents
occurred_on
payment_method
external_reference

payer_name
payer_username
raw_text

matched_party_id
matched_tenancy_id

status                     NOT NULL
error_message

confirmed_source_type
confirmed_source_id

created_at
updated_at
```

This closely follows the PRD model. 

Replace the current fields:

```text
amount                 -> amount_cents
payment_date           -> occurred_on
transaction_number     -> external_reference

party_id               -> matched_party_id
tenancy_id             -> matched_tenancy_id

payment_document_id    -> source_document_id

receipt_id             -> confirmed_source_type/id
receipt_type           -> SourceDocument.document_type
```

The current schema still uses decimal `amount`, `payment_date`, `receipt_type`, `transaction_number`, and a Receipt-specific FK. 

---

# 6. Store imported money in cents immediately

Do not keep:

```text
decimal amount
```

on `ImportedTransaction`.

Use:

```text
amount_cents BIGINT
```

with:

```text
amount_cents IS NULL OR amount_cents > 0
```

`NULL` remains necessary because failed/partial parses are persisted for manual review.

Parsers should produce integer cents, so the pipeline becomes:

```text
PDF text
 -> parser
 -> Integer cents
 -> ImportedTransaction
 -> domain CreateService
```

rather than carrying `BigDecimal` into persistence as the current parser result does. 

At the HTTP boundary continue accepting dollars through a virtual `amount` field or explicit parser. Do not permit `amount_cents` in public strong parameters.

---

# 7. Separate document type from financial transaction kind

This distinction is load-bearing.

```text
document_type:
  zelle
  venmo
  chase_statement

transaction_kind:
  unknown
  tenant_receipt
  security_deposit
```

A Zelle document tells Yanushi **how the money moved**, not **why Yanushi is holding it**.

The same Zelle payment could be:

```text
monthly rent
security deposit
```

The PRD deliberately treats `transaction_kind` as a candidate that may be unknown. 

---

# 8. Default `transaction_kind` to `unknown`

I would **not** translate every existing parsed payment into:

```text
tenant_receipt
```

by default.

That recreates exactly the failure Milestone 7 is supposed to eliminate: a refundable deposit could accidentally become an ordinary Receipt simply because it arrived through Zelle or Venmo.

Initial parsing should normally produce:

```text
transaction_kind = unknown
```

unless a future parser has genuinely reliable semantic evidence.

The user must choose:

```text
Tenant payment
Refundable security deposit
```

before confirmation.

The PRD explicitly requires that security deposits cannot accidentally become rent receipts. 

---

# 9. Database constraints

Add checks for:

```text
transaction_kind IN (
  'unknown',
  'tenant_receipt',
  'security_deposit'
)
```

and existing statuses:

```text
pending
matched
unmatched
ambiguous
confirmed
failed
```

Require paired confirmation provenance:

```text
confirmed_source_type IS NULL
IFF
confirmed_source_id IS NULL
```

Require:

```text
status = 'confirmed'
IFF
confirmed_source_type/id are present
```

Restrict confirmed types to:

```text
Receipt
SecurityDepositTransaction
```

at the model layer and, if convenient, via a SQL check constraint.

---

# 10. Polymorphic confirmed-source provenance

Use:

```ruby
belongs_to :confirmed_source,
  polymorphic: true,
  optional: true
```

instead of a Receipt-specific association.

Add the reverse relation where useful:

```ruby
Receipt
  has_one :imported_transaction,
    as: :confirmed_source

SecurityDepositTransaction
  has_one :imported_transaction,
    as: :confirmed_source
```

Add a unique partial index:

```text
UNIQUE (
  confirmed_source_type,
  confirmed_source_id
)
WHERE confirmed_source_id IS NOT NULL
```

One confirmed financial source event should have at most one import provenance record.

---

# 11. Preserve provenance through later corrections

Do **not** retarget:

```text
ImportedTransaction.confirmed_source
```

when a Receipt or deposit transaction is corrected.

Example:

```text
ImportedTransaction
    ↓
Receipt #10
    ↓ corrected
Receipt #11
```

The import remains linked to `Receipt #10`.

Likewise:

```text
ImportedTransaction
    ↓
SecurityDepositTransaction #20
    ↓ corrected
SecurityDepositTransaction #21
```

The original source is the event actually created by confirmation.

The existing ingestion code already preserves Receipt provenance this way; retain that property across the polymorphic generalization. 

---

# 12. Rename the ingestion namespace cleanly

Replace:

```text
PaymentIngestions::
PaymentDocuments::
```

with:

```text
ImportedTransactions::
SourceDocuments::
```

For example:

```text
PaymentIngestions::Ingestion
    -> ImportedTransactions::IngestionService

PaymentIngestions::ConfirmService
    -> ImportedTransactions::ConfirmService

PaymentIngestions::UpdateService
    -> ImportedTransactions::UpdateService

PaymentIngestions::DestroyService
    -> ImportedTransactions::DestroyService

PaymentIngestions::IndexQuery
    -> ImportedTransactions::IndexQuery

PaymentIngestions::FormDataQuery
    -> ImportedTransactions::FormDataQuery

PaymentDocuments::DestroyService
    -> SourceDocuments::DestroyService

IngestPaymentDocumentJob
    -> IngestSourceDocumentJob
```

Do the same for parsers and helpers.

No compatibility namespace is needed.

---

# 13. Rename `TenantResolver`

The existing `TenantResolver` already actually resolves `Party` records and `PartyAlias` records. 

Rename it:

```text
ImportedTransactions::PartyResolver
```

Its result should remain:

```text
matched
ambiguous
unmatched
```

with candidate Parties.

This removes the last misleading pre-domain-model terminology.

---

# 14. Keep Party matching and Tenancy matching separate

The imported transaction stores:

```text
matched_party
matched_tenancy
```

They are related suggestions, not one combined identity.

A payer may be:

- a tenant;
- a guarantor;
- a parent;
- an employer;
- some other Party.

The final Receipt model already permits payer identity to differ from tenancy membership, and the same must be true for security-deposit contributors. 

Therefore:

```text
payer must belong to user
tenancy must belong to user
```

but do **not** require:

```text
payer is a TenancyParty of tenancy
```

for manual confirmation.

Party/Tenancy membership should improve suggestions, not constrain valid money movement.

---

# 15. Automatic tenancy suggestion

When parsing provides a Party and an accounting date:

```text
find the Party's tenancies active on occurred_on
```

Then:

```text
exactly one -> suggest it
multiple    -> ambiguous
none        -> no tenancy match
```

The current pipeline already approximates this behavior using active tenancies. 

Do not fall back to `Date.current` when the parsed date is absent.

Without an accounting date, leave the tenancy unresolved rather than guessing based on today's occupancy.

---

# 16. Stop inventing parser dates

There are two existing fallback behaviors worth removing during the generalization.

The Chase parser currently uses today's year when the statement period cannot be parsed and even returns `Date.current` if an individual transaction date cannot be constructed. 

For financial ingestion:

```text
unknown date
```

is safer than:

```text
plausible but invented accounting date
```

So:

- missing/invalid standalone date -> `occurred_on = nil`;
- unresolvable Chase statement year -> failed/partial candidate;
- never substitute `Date.current` for a parse failure.

The review form already exists specifically to correct incomplete parse results.

---

# 17. Do not drop unmatched Chase transactions

The current Chase pipeline discards parsed statement transactions when the Party resolver returns `unmatched`. 

Remove that behavior.

A parsed incoming transaction from an unknown Party should become:

```text
ImportedTransaction(status: unmatched)
```

so the user can:

- associate an existing Party;
- create a Party;
- choose the Tenancy;
- classify the transaction.

This is especially important for a first-time payer or security-deposit contributor.

No parser should silently discard a syntactically valid incoming-money event merely because Yanushi doesn't recognize the payer yet.

---

# 18. Generalize the parser result object

Replace fields such as:

```text
receipt_type
amount
payment_date
transaction_number
```

with:

```text
document_type
amount_cents
occurred_on
external_reference
payment_method
payer_name
payer_username
raw_text
error_message
```

`transaction_kind` should normally be assigned by the ingestion/classification layer as `unknown`, not inferred from `document_type`.

The existing `IngestionResult` is still Receipt-centric. 

---

# 19. Source-specific duplicate identity

Use external transaction identity whenever reliable, as required by the PRD. 

Add a partial unique index along the lines of:

```text
UNIQUE (
  user_id,
  source,
  payment_method,
  external_reference
)
WHERE
  payment_method IS NOT NULL
  AND external_reference IS NOT NULL
```

This protects against:

```text
upload Zelle receipt
upload same Zelle receipt again
```

before either candidate can become duplicate money.

Do **not** use:

```text
amount
date
payer
```

as a hard duplicate identity.

Two legitimate monthly payments can have exactly the same three values; the PRD explicitly rejects that heuristic. 

---

# 20. Do not over-restrict `external_reference`

The current `transaction_number` validation permits only a narrow alphanumeric/dash/underscore format. 

The generalized `external_reference` should not assume every future provider's identity syntax.

Use:

```text
trim whitespace
reasonable max length
```

but avoid a provider-specific regexp unless a parser itself validates a provider-specific format.

---

# 21. Handle duplicate documents gracefully during parsing

If a parser produces an external identity already represented by another `ImportedTransaction`:

- do not create another candidate;
- do not fail all other transactions in a multi-transaction statement;
- let the document complete;
- optionally report how many transactions were skipped as already imported.

For a Chase statement:

```text
10 parsed incoming transactions
2 already imported
8 new
```

should produce the eight new candidates rather than failing the whole statement.

The database unique index remains the race-safe final authority.

---

# 22. Define `confirmable?` by kind

Common confirmation requirements:

```text
status != confirmed
matched_party present
matched_tenancy present
amount_cents > 0
occurred_on present
transaction_kind != unknown
no duplicate external identity conflict
```

Then branch.

### `tenant_receipt`

Additionally require:

```text
payment_method present
```

### `security_deposit`

Additionally require:

```text
matched_tenancy.security_deposit present
```

This distinction should live in domain/service code, not only the view.

---

# 23. Do not auto-create a SecurityDeposit during confirmation

If:

```text
transaction_kind = security_deposit
```

but the matched Tenancy has no `SecurityDeposit` aggregate, confirmation should fail with something like:

```text
No security-deposit requirement exists for this tenancy.
Set up the security deposit before confirming this import.
```

Do **not** invent:

```text
required_amount = imported amount
due_on = imported date
```

Those are contractual facts Yanushi does not know.

Milestone 6 deliberately models the requirement separately from money held. 

---

# 24. Generalized `ConfirmService`

Create:

```text
ImportedTransactions::ConfirmService
```

The core algorithm should be:

```text
validate user ownership

transaction do
  lock SourceDocument
  lock ImportedTransaction
  reload

  if already confirmed
    return existing confirmed_source
  end

  validate current confirmability

  case transaction_kind
  when tenant_receipt
    create/post Receipt
  when security_deposit
    create/post deposit received transaction
  else
    fail
  end

  optionally create Party aliases

  store confirmed_source
  mark confirmed
end
```

The existing confirmation flow already establishes the important `PaymentDocument -> PaymentIngestion` lock ordering; preserve it as `SourceDocument -> ImportedTransaction`. 

---

# 25. Receipt confirmation branch

For:

```text
transaction_kind = tenant_receipt
```

call:

```ruby
Receipts::CreateService.call(
  tenancy: imported_transaction.matched_tenancy,
  payer_party: imported_transaction.matched_party,
  amount_cents: imported_transaction.amount_cents,
  received_on: imported_transaction.occurred_on,
  payment_method: imported_transaction.payment_method,
  external_reference: imported_transaction.external_reference
)
```

That existing service already creates the source record and journal entry atomically. 

On success:

```text
confirmed_source = Receipt
status = confirmed
```

---

# 26. Security-deposit confirmation branch

For:

```text
transaction_kind = security_deposit
```

resolve:

```text
security_deposit =
  matched_tenancy.security_deposit
```

and call:

```ruby
SecurityDepositTransactions::ReceiveService.call(
  security_deposit: security_deposit,
  party: imported_transaction.matched_party,
  amount_cents: imported_transaction.amount_cents,
  occurred_on: imported_transaction.occurred_on,
  external_reference: imported_transaction.external_reference
)
```

The Milestone 6 service already owns:

- SecurityDeposit aggregate locking;
- historical liability validation;
- deposit posting;
- posted-state transition. 

Do not duplicate those mechanics inside ingestion.

On success:

```text
confirmed_source = SecurityDepositTransaction(received)
status = confirmed
```

And assert:

```text
Receipt.count unchanged
Tenant Receivable unchanged
```

---

# 27. One confirmation transaction owns everything

The outer confirmation transaction must include:

```text
domain source creation
journal posting
alias creation
confirmed_source assignment
confirmed status
```

If any final step fails:

```text
no Receipt/SD transaction
no JournalEntry
no alias
import remains unconfirmed
```

Nested domain-service transactions should participate in the outer transaction rather than committing independently.

The PRD explicitly requires all durable confirmation changes to be atomic. 

---

# 28. Confirmation idempotency

Repeated calls:

```ruby
ConfirmService.call(import)
ConfirmService.call(import)
```

must return:

```text
same confirmed_source
```

for **both** types.

Expected counts:

```text
tenant_receipt:
  1 Receipt
  1 JournalEntry

security_deposit:
  1 SecurityDepositTransaction
  1 JournalEntry
```

Never two.

This is a direct Milestone 7 acceptance requirement. 

---

# 29. Concurrent confirmation

Retain and expand the existing real-thread concurrency coverage. The current `PaymentIngestion` suite already tests simultaneous confirmation against update/delete/document-delete and duplicate confirmation. 

Test:

```text
confirm vs confirm
```

for both transaction kinds.

Both callers may return success, but:

```text
same confirmed_source id
one financial source
one journal entry
```

---

# 30. Confirmation vs classification update

Race:

```text
Thread A:
  transaction_kind = tenant_receipt -> save

Thread B:
  confirm
```

or vice versa.

Because both operations lock `ImportedTransaction`, terminal state must be coherent:

```text
update wins first:
  confirmation uses new persisted kind

confirmation wins first:
  later update fails immutable
```

Never:

```text
import says security_deposit
confirmed_source is Receipt
```

---

# 31. Confirmation vs Party/Tenancy update

Retain the same invariant for:

```text
matched_party
matched_tenancy
amount
occurred_on
external_reference
```

Once confirmation owns the import row lock, it must create the financial source from the values that survive serialization.

After confirmed:

```text
all candidate fields immutable
```

---

# 32. Confirmation vs import deletion

Retain the existing behavior:

```text
confirm wins:
  import becomes immutable
  delete fails

delete wins:
  import disappears
  no financial source
```

Never:

```text
financial source committed
provenance record deleted
```

The current code already has this concurrency contract; carry it through the rename. 

---

# 33. Confirmation vs SourceDocument deletion

Preserve lock ordering:

```text
SourceDocument
    ↓
ImportedTransaction(s)
```

Both:

```text
ConfirmService
SourceDocuments::DestroyService
```

must follow it.

If any child is confirmed:

```text
SourceDocument deletion fails
```

The current implementation already serializes document deletion against confirmation this way. 

---

# 34. Confirmed imports are immutable

After confirmation reject changes to:

```text
source_document
source
transaction_kind
amount_cents
occurred_on
payment_method
external_reference
payer_name
payer_username
raw_text
matched_party
matched_tenancy
status
confirmed_source
```

and reject deletion.

Keep the current defense against stale model objects by checking persisted database state rather than trusting only the in-memory `status_was`. The existing `PaymentIngestion` model does this intentionally. 

---

# 35. Validate confirmed-source consistency

For a confirmed Receipt:

```text
confirmed_source.tenancy ==
matched_tenancy

confirmed_source.payer_party ==
matched_party

confirmed_source.amount_cents ==
amount_cents
```

For a confirmed deposit transaction:

```text
confirmed_source.security_deposit.tenancy ==
matched_tenancy

confirmed_source.party ==
matched_party

confirmed_source.amount_cents ==
amount_cents

confirmed_source.transaction_kind ==
received
```

These are primarily service invariants, but model validation can defend obvious corrupt combinations.

---

# 36. Alias behavior remains cross-kind

The current confirmation service can add the parsed payer name/username as aliases for the selected Party. 

Retain this for:

```text
tenant_receipt
security_deposit
```

An imported security deposit is just as useful for teaching Yanushi that:

```text
@janedoe123 -> Jane Doe
```

Aliases remain part of the confirmation transaction.

---

# 37. Review UI

Rename:

```text
Payment Ingestions
```

to something such as:

```text
Transaction Imports
```

or:

```text
Imported Transactions
```

The review page should show:

```text
Source document
Parsed payer identity
Matched Party
Matched Tenancy
Occurred on
Amount
Payment method
External reference
Transaction type
```

Add the required selector:

```text
Transaction type

[ Needs classification           ]
[ Tenant payment                 ]
[ Refundable security deposit    ]
```

---

# 38. Make the financial consequence visible before confirmation

When `tenant_receipt` is selected, show concise explanatory copy:

```text
This will record an ordinary tenant payment
and reduce the tenancy's receivable balance.
```

When `security_deposit` is selected:

```text
This will record refundable deposit funds.
It will increase security-deposit liability
and will not reduce tenant receivable.
```

This is not bookkeeping UI; it is preventing an important semantic misclassification.

---

# 39. Security-deposit confirmation context

For a deposit candidate, display:

```text
Required deposit
Currently held
Amount being received
Held after confirmation
```

using the existing SecurityDeposit queries.

If no SecurityDeposit exists:

```text
Security deposit has not been configured for this tenancy.
```

and disable confirmation server-side and in the UI.

Provide a link to setup.

---

# 40. Dynamic confirmation button

Instead of the current fixed:

```text
Confirm & Record Payment Receipt
```

use:

```text
tenant_receipt:
  Confirm & Record Payment

security_deposit:
  Confirm & Record Security Deposit

unknown:
  disabled — Select transaction type
```

The current view is still explicitly Receipt-only. 

---

# 41. Confirmed banner/link is polymorphic

For Receipt:

```text
Confirmed as Tenant Payment
View Receipt
```

For deposit:

```text
Confirmed as Security Deposit
View Deposit Transaction
```

Use:

```ruby
polymorphic_path(imported_transaction.confirmed_source)
```

rather than type-specific controller branching where possible.

---

# 42. Routes

I'd separate upload/document ownership from transaction review:

```ruby
resources :source_documents, only: %i[new create destroy] do
  member do
    get :download
  end
end

resources :imported_transactions, only: %i[index show update destroy] do
  member do
    post :confirm
  end
end
```

The current system puts document upload/download under `payment_ingestions`; generalization is a good opportunity to put document behavior on `SourceDocument`. 

No legacy route redirects are necessary.

---

# 43. Upload service

Create:

```text
SourceDocuments::UploadService
```

Preserve the current limits unless there's another reason to change them:

```text
PDF only
10 MB maximum
background parsing job
```

The existing upload service already enforces these rules. 

Upload creates:

```text
SourceDocument(status: processing, document_type: unknown)
```

then enqueues:

```text
IngestSourceDocumentJob
```

---

# 44. Ingestion job

The job should:

1. lock/load SourceDocument metadata as necessary;
2. extract text;
3. identify `document_type`;
4. update the SourceDocument type;
5. parse transaction candidates;
6. match Party/Tenancy suggestions;
7. persist `ImportedTransaction`s;
8. mark document success or failed.

No step creates:

```text
Receipt
SecurityDepositTransaction
JournalEntry
Posting
```

The current job already limits itself to ingestion records; preserve that separation. 

---

# 45. Unconfirmed candidates never affect durable financial state

Add an explicit acceptance test:

```text
upload + parse document

Receipt.count                         unchanged
SecurityDepositTransaction.count     unchanged
JournalEntry.count                    unchanged
Posting.count                         unchanged
Tenant Receivable                     unchanged
Security Deposit liability            unchanged
```

Then save manual corrections/classification and assert the same again.

Only `confirm` crosses the financial boundary.

This is explicitly one of the four Milestone 7 done-when conditions. 

---

# 46. Reviewable states

Keep:

```text
matched
unmatched
ambiguous
failed
```

reviewable.

A transaction can be:

```text
status = matched
transaction_kind = unknown
```

That's okay.

`matched` means:

```text
identity/location matching has been resolved
```

not:

```text
ready to post
```

`confirmable?` remains the authoritative readiness check.

---

# 47. Unknown Party workflow

A valid import from an unknown payer should not disappear.

At minimum, the review page should allow the user to:

```text
select any existing Party
```

and offer:

```text
Create Party
```

when none fits.

If inline Party creation becomes too much UI work for the milestone, link through the existing Party creation flow and return to the import.

Do not create a Party automatically merely from parsed text.

---

# 48. Index queue

Generalize the current `IndexQuery` to return:

```text
reviewable_transactions
confirmed_transactions
processing_documents
failed_documents
```

and preload:

```text
matched_party
matched_tenancy -> rentable_unit -> property
confirmed_source
source_document
```

The current query already has essentially this structure under payment-specific names. 

Add transaction-kind badges:

```text
Payment
Security Deposit
Needs Classification
```

---

# 49. Duplicate presentation

Replace Receipt-specific copy such as:

```text
Duplicate Payment Detected
```

with:

```text
Duplicate Imported Transaction
```

The warning should describe:

```text
payment method
external reference
existing import
```

not imply the existing final source is necessarily a Receipt.

---

# 50. Security deposit final source doesn't need `payment_method`

Do not modify the Milestone 6 transaction schema merely so a confirmed deposit can copy every import field.

The provenance split is:

```text
ImportedTransaction:
  how/source metadata
  payment_method
  parser data

SecurityDepositTransaction:
  financially meaningful deposit event
  party
  amount
  date
  external_reference
```

That is precisely why the `ImportedTransaction -> confirmed_source` relationship exists.

---

# 51. External-reference duplication semantics

For imported records with reliable identity:

```text
same user
same source
same payment method
same external reference
```

means the same imported external transaction.

But:

```text
same amount
same date
same payer
different external reference
```

must be allowed.

Also allow legitimate imports with no external reference; lack of an ID must not cause amount/date heuristic deduplication. The PRD specifically calls this out. 

---

# 52. Final-source duplicate failures remain transactional

Receipt creation already has its own unique active external-reference protection. 

If that fails during confirmation:

```text
ImportedTransaction remains unconfirmed
no partial alias
no partially stored confirmed_source
```

Likewise any security-deposit ReceiveService failure rolls the outer confirmation back.

Return the actual domain-service failure rather than masking it as a generic ingestion error.

---

# 53. Do not add deposit duplicate heuristics to the domain model

`SecurityDepositTransaction` does not persist `payment_method`.

Therefore don't invent a hard duplicate rule like:

```text
same external_reference alone == duplicate deposit
```

at the deposit model layer.

Provider/source-specific deduplication belongs to `ImportedTransaction`, where the full external identity is available.

Manual deposit entry and import deduplication can be revisited later if a durable payment-provider identity becomes part of the financial source model.

---

# 54. Model associations

Update:

```ruby
User
  has_many :source_documents
  has_many :imported_transactions

SourceDocument
  belongs_to :user
  has_many :imported_transactions

ImportedTransaction
  belongs_to :user
  belongs_to :source_document
  belongs_to :matched_party,
    class_name: "Party",
    optional: true
  belongs_to :matched_tenancy,
    class_name: "Tenancy",
    optional: true
  belongs_to :confirmed_source,
    polymorphic: true,
    optional: true
```

Remove the old payment associations completely.

---

# 55. SourceDocument deletion

Keep:

```text
unconfirmed-only document
    -> deletable

any confirmed ImportedTransaction
    -> immutable document
```

When deletable:

```text
SourceDocument destroy
    -> destroy unconfirmed imported candidates
```

A confirmed financial source is never cascaded.

The current document lifecycle already protects this boundary; preserve it through the rename. 

---

# 56. RBS

Add/rename signatures for:

```text
SourceDocument
ImportedTransaction

SourceDocuments::UploadService
SourceDocuments::DestroyService

ImportedTransactions::IngestionService
ImportedTransactions::ConfirmService
ImportedTransactions::UpdateService
ImportedTransactions::DestroyService
ImportedTransactions::PartyResolver

ImportedTransactions::Parsers::Base
ImportedTransactions::Parsers::Zelle
ImportedTransactions::Parsers::Venmo
ImportedTransactions::Parsers::ChaseStatement

ImportedTransactions::IndexQuery
ImportedTransactions::FormDataQuery
```

Type:

```text
amount_cents: Integer?
occurred_on: Date?
transaction_kind: String
confirmed_source: Receipt | SecurityDepositTransaction | nil
```

Avoid `untyped` around the new financial dispatch boundary.

---

# 57. Factories

Replace:

```text
payment_document
payment_ingestion
```

with:

```text
source_document
imported_transaction
```

Useful traits:

```text
:tenant_receipt
:security_deposit
:unknown_kind

:matched
:unmatched
:ambiguous
:failed
:confirmed_receipt
:confirmed_security_deposit
```

For confirmed traits, prefer using `ConfirmService` in integration tests rather than manufacturing an inconsistent confirmed row.

---

# 58. Parser tests

For each parser pin:

```text
payer_name
payer_username
amount_cents
occurred_on
payment_method
external_reference
raw_text
document_type
```

Also test:

```text
missing date -> nil, not Date.current
invalid date -> nil/failure, not Date.current
```

For Chase:

```text
unmatched incoming transaction remains an import candidate
```

rather than being discarded.

---

# 59. Ordinary Receipt acceptance test

Given:

```text
ImportedTransaction
  transaction_kind: tenant_receipt
  payer: Alice
  tenancy: Unit A
  amount: $2,000
```

confirm.

Expected:

```text
1 Receipt
1 JournalEntry
2 Postings

Cash                 +$2,000
Tenant Receivable    -$2,000

confirmed_source == Receipt
status == confirmed
```

The payer identity on the Receipt must be Alice.

---

# 60. Security deposit acceptance test

Given:

```text
SecurityDeposit requirement exists

ImportedTransaction
  transaction_kind: security_deposit
  payer: Alice
  tenancy: Unit A
  amount: $2,000
```

confirm.

Expected:

```text
0 new Receipts

1 SecurityDepositTransaction(received)
1 JournalEntry
2 Postings

Cash                       +$2,000
Security Deposits Held     +$2,000 liability

Tenant Receivable          unchanged
```

And:

```text
confirmed_source ==
  SecurityDepositTransaction
```

This directly pins the most important Milestone 7 distinction. 

---

# 61. Classification safety acceptance

Start with:

```text
transaction_kind = unknown
```

Attempt confirmation.

Expected:

```text
failure :classification_required

Receipt                    unchanged
SecurityDepositTransaction unchanged
JournalEntry               unchanged
```

Then classify as:

```text
security_deposit
```

and confirm.

Prove that no Receipt was ever created.

---

# 62. Missing SecurityDeposit acceptance

For:

```text
security_deposit import
matched tenancy has no SecurityDeposit
```

confirmation fails.

Expected:

```text
no SecurityDeposit aggregate auto-created
no SecurityDepositTransaction
no Receipt
no JournalEntry
import remains reviewable
```

---

# 63. Third-party payer acceptance

Given:

```text
Party = Tenant's parent
Party is not a TenancyParty
Tenancy = child's tenancy
```

confirm either:

```text
tenant_receipt
```

or:

```text
security_deposit
```

Expected success.

The final source preserves the actual payer/contributor Party.

---

# 64. Duplicate confirmation acceptance

For both kinds:

```text
confirm import
confirm same import again
```

Expected:

```text
same returned source id
one financial source
one journal entry
```

Then run the same test with two threads.

---

# 65. Duplicate external import acceptance

Upload/parse two documents containing:

```text
same source
same payment method
same external reference
```

Expected:

```text
one ImportedTransaction for that external identity
```

or one reviewable candidate plus an explicit duplicate/skipped result, depending on UI implementation.

Never two independently confirmable candidates.

---

# 66. Legitimate repeated payment acceptance

Given:

```text
Jan 1  Alice  $2,000  external_ref=A
Feb 1  Alice  $2,000  external_ref=B
```

both imports must survive and be confirmable.

Do not mistake amount/date/payer similarity for identity.

---

# 67. No-ledger-before-confirmation acceptance

This deserves a top-level feature spec.

After:

```text
upload
parse
auto-match
manual update
classification
```

but before confirmation:

```text
JournalEntry.count = unchanged
Posting.count = unchanged

Cash = unchanged
Tenant Receivable = unchanged
Deposit liability = unchanged
```

Then confirm and assert the appropriate one and only one domain accounting event appears.

---

# 68. Provenance-after-correction tests

### Receipt

```text
import -> Receipt A
correct A -> Receipt B

import.confirmed_source == A
A.superseded_by == B
```

### Deposit

```text
import -> DepositTransaction A
correct A -> DepositTransaction B

import.confirmed_source == A
A.superseded_by == B
```

The import explains the origin of the original event; correction history explains everything thereafter.

---

# 69. Concurrency matrix

At minimum add threaded tests for:

```text
confirm vs confirm
confirm vs update
confirm vs destroy import
confirm vs destroy source document
```

for:

```text
tenant_receipt
security_deposit
```

Plus:

```text
classification update vs confirm
matched tenancy update vs confirm
```

Assertions should focus on terminal invariants, not which thread wins.

---

# 70. Suggested commit sequence

### Commit 1 — Generalize schema/domain

```text
SourceDocument
ImportedTransaction
table/column renames
polymorphic confirmed source
constraints
associations
factories
```

### Commit 2 — Generalize parsing/matching

```text
ImportedTransactions namespace
PartyResolver
IngestionResult
integer cents
date handling
unmatched Chase candidates
SourceDocument document_type
```

### Commit 3 — Generalize upload lifecycle

```text
SourceDocuments::UploadService
IngestSourceDocumentJob
SourceDocuments::DestroyService
routes/controllers
```

### Commit 4 — General confirmation

```text
ImportedTransactions::ConfirmService
Receipt branch
confirmed_source provenance
idempotency
alias handling
```

### Commit 5 — Security-deposit confirmation

```text
security_deposit classification
ReceiveService dispatch
missing-deposit handling
deposit acceptance tests
```

### Commit 6 — UI

```text
transaction classification
generalized copy
deposit context
polymorphic confirmed banner/link
index queue
duplicate presentation
```

### Commit 7 — Concurrency/idempotency

```text
external identity index
confirm races
update/delete/document races
cross-upload duplicate tests
rollback tests
```

### Commit 8 — Types/docs/cleanup

```text
RBS
Steep
remove Payment* names
documentation
full quality gate
```

---

# 71. Stale-name sweep

At the end:

```bash
rg -n \
  'PaymentDocument|PaymentIngestion|PaymentIngestions|PaymentDocuments|payment_document|payment_ingestion|TenantResolver|receipt_type|transaction_number|payment_date' \
  app config db spec sig
```

Expected remaining matches:

```text
none
```

except perhaps historical migration filenames if intentionally retained.

Also:

```bash
rg -n \
  'confirmed_source|transaction_kind|SourceDocument|ImportedTransaction' \
  app config db spec sig
```

to audit every new boundary.

---

# 72. Financial-boundary sweep

Search production ingestion code for direct creation of accounting sources:

```bash
rg -n \
  'Receipt\.(new|create|create!)|SecurityDepositTransaction\.(new|create|create!)|JournalEntry\.(new|create|create!)|Posting\.(new|create|create!)' \
  app/services/imported_transactions \
  app/controllers
```

Expected:

```text
no direct financial persistence
```

Confirmation should call:

```text
Receipts::CreateService
SecurityDepositTransactions::ReceiveService
```

only.

That keeps ingestion as an orchestration layer rather than a second accounting implementation.

---

# 73. Quality gate

Run:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate

bundle exec rspec

bundle exec rbs validate
bundle exec steep check

bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

Because this milestone is a clean naming/schema cutover, the empty-database migration path is particularly important.

---

# Milestone 7 done-when checklist

### Generalization

- [ ] `PaymentDocument` is gone.
- [ ] `PaymentIngestion` is gone.
- [ ] `SourceDocument` exists.
- [ ] `ImportedTransaction` exists.
- [ ] Imported money is stored in integer cents.
- [ ] Party/Tenancy matching uses the new domain names.
- [ ] Unknown payers are retained for review rather than silently dropped.

### Classification

- [ ] `tenant_receipt` exists.
- [ ] `security_deposit` exists.
- [ ] `unknown` exists.
- [ ] `unknown` cannot confirm.
- [ ] Zelle/Venmo document type does not imply financial kind.

### Ordinary receipts

- [ ] Confirmation creates a `Receipt`.
- [ ] Receipt payer is the matched Party.
- [ ] Receipt tenancy is the matched Tenancy.
- [ ] Receipt preserves the external reference.
- [ ] Receipt posts exactly once.

### Security deposits

- [ ] Confirmation creates `SecurityDepositTransaction(received)`.
- [ ] It never creates a Receipt.
- [ ] Existing SecurityDeposit aggregate is required.
- [ ] Deposit requirement is never invented from import data.
- [ ] Cash increases.
- [ ] Deposit liability increases.
- [ ] Tenant Receivable does not change.

### Provenance

- [ ] `confirmed_source` supports both final source types.
- [ ] Confirmed source is immutable.
- [ ] Import preserves parsed payer identity.
- [ ] Import remains linked to the original source after correction.
- [ ] Confirmed SourceDocument cannot be deleted.

### Idempotency/concurrency

- [ ] Same import confirmed twice creates one financial event.
- [ ] Concurrent confirmation creates one financial event.
- [ ] Confirm/update race remains coherent.
- [ ] Confirm/delete race remains coherent.
- [ ] Confirm/document-delete race remains coherent.
- [ ] Duplicate external identities cannot create two reviewable imports.
- [ ] Identical amount/date/payer alone is not treated as identity.

### Ledger isolation

- [ ] Upload creates no ledger entry.
- [ ] Parsing creates no ledger entry.
- [ ] Matching creates no ledger entry.
- [ ] Manual review creates no ledger entry.
- [ ] Classification creates no ledger entry.
- [ ] Only confirmation crosses into financial state.

Those last four properties are the essence of Milestone 7: **ingestion describes possible financial events; confirmation creates the actual domain event; the domain service creates the accounting event.** That keeps the parser, matching heuristics, and user corrections safely outside financial truth until the user explicitly confirms them. 

The design choice I'd be most deliberate about is **defaulting `transaction_kind` to `unknown`**. Automatically treating the existing Zelle/Venmo pipeline as `tenant_receipt` would make the rename easier, but it would weaken the exact safety property Milestone 7 exists to introduce.
