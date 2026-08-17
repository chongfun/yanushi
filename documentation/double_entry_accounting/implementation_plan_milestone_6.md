# Implementation Plan: Milestone 6 — Security Deposits

## 1. Objective

Implement:

```text
Tenancy
└── SecurityDeposit
    └── SecurityDepositTransaction
        ├── received
        ├── refunded
        └── applied
```

with accounting:

```text
Deposit received
  Dr Cash
  Cr Security Deposits Held

Deposit refunded
  Dr Security Deposits Held
  Cr Cash

Deposit applied
  Dr Security Deposits Held
  Cr Tenant Receivable
```

The last operation settles an already-existing Charge. It does **not** recognize income again. 

At the end of the milestone:

- deposit requirement is visible on the Tenancy;
- deposit held is derived from accounting postings;
- money can be received into the deposit liability;
- held money can be refunded;
- held money can be applied against an existing Charge;
- liability can never go negative;
- deposits never become ordinary `Receipt`s;
- security deposits never contribute to ordinary rent-received reporting. 

---

## 2. Milestone boundary

Implement:

- `SecurityDeposit`;
- `SecurityDepositTransaction`;
- deposit requirement;
- deposit receipt;
- deposit refund;
- deposit application;
- deposit transaction void/correction;
- held-liability query;
- tenancy UI;
- interim property activity;
- concurrency protection;
- integration with Charge lifecycle.

Do **not** implement:

- `SourceDocument` / `ImportedTransaction`;
- automatic deposit detection during ingestion;
- trust/escrow bank accounts;
- interest-bearing deposits;
- jurisdiction-specific security-deposit law;
- deposit deductions without an existing Charge;
- deposit allocation across arbitrary accounting entries;
- bank reconciliation;
- final ledger/reporting rewrite.

Milestone 7 will generalize ingestion so confirmation can choose either an ordinary Receipt or a security-deposit transaction. 

---

# 3. Preserve the conceptual separation from `Receipt`

Do not add:

```text
receipt_kind = security_deposit
```

and do not add:

```text
is_security_deposit
```

to `Receipt`.

A Receipt currently posts against Tenant Receivable, which is exactly what a refundable deposit must **not** do. The current tenancy balance is already calculated solely from Tenant Receivable postings. 

The domain distinction should remain:

```text
Receipt
  money credited to the tenancy running account

SecurityDepositTransaction(received)
  money held as a refundable liability
```

---

# 4. Establish the baseline

Before implementation:

```bash
git status --short

bundle exec rspec
bundle exec rbs validate
bundle exec steep check
bin/rubocop
bin/brakeman --no-pager
```

Then inventory relevant code:

```bash
rg -n \
  'security_deposit|Receipt|tenant_receivable|security_deposits_held|financial_history|current_balance|BalanceQuery' \
  app config db spec sig documentation
```

Also identify Charge lifecycle paths:

```bash
rg -n \
  'Charges::VoidService|Charges::CorrectService|superseded_by|voided_at' \
  app spec
```

Deposit application will introduce a new dependency on Charge lifecycle.

---

# 5. Create `security_deposits`

Use one deposit aggregate per Tenancy:

```text
security_deposits

id
tenancy_id                 NOT NULL
required_amount_cents      BIGINT NOT NULL
due_on                     DATE NOT NULL
created_at                 NOT NULL
updated_at                 NOT NULL
```

Add:

```text
UNIQUE(tenancy_id)
```

The PRD models `SecurityDeposit` as the contractual requirement and explicitly says that the amount held is derived from its transactions rather than stored as a mutable balance. 

Absence of a `SecurityDeposit` means:

```text
no security-deposit requirement recorded
```

Do not create zero-dollar placeholder rows.

---

# 6. SecurityDeposit model

Create:

```ruby
class SecurityDeposit < ApplicationRecord
  belongs_to :tenancy

  has_many :transactions,
    class_name: "SecurityDepositTransaction",
    dependent: :restrict_with_error

  def accounting_user
    tenancy&.accounting_user
  end
end
```

Validate:

```text
required_amount_cents > 0
due_on present
tenancy present
one deposit per tenancy
```

---

# 7. Requirement mutability

`SecurityDeposit` itself is **not** a posted financial event.

However, because the schema has no effective-dated requirement history, keep the MVP rule conservative:

```text
before any deposit transaction:
  requirement and due date may be edited

after any deposit transaction exists:
  required_amount_cents and due_on are immutable
```

Otherwise changing a `$2,000` historical requirement to `$3,000` after years of activity rewrites what the aggregate appears to have required at the time.

If future requirements need to change mid-tenancy, introduce effective-dated requirement terms later rather than silently mutating historical contractual state.

---

# 8. Create `security_deposit_transactions`

Target:

```text
security_deposit_transactions

id
security_deposit_id        NOT NULL
transaction_kind           NOT NULL
amount_cents               BIGINT NOT NULL
occurred_on                DATE NOT NULL

party_id                    NULL
charge_id                   NULL
external_reference          NULL
memo                        NULL

posted_at                   NULL
voided_at                   NULL
superseded_by_id            NULL

created_at                  NOT NULL
updated_at                  NOT NULL
```

The PRD's core fields are deposit, kind, cents, accounting date, Party, optional Charge/reference, and posting lifecycle. Add `superseded_by_id` to support the project's established correction model rather than destructive editing. 

---

# 9. Database constraints

Require:

```text
amount_cents > 0
```

Restrict `transaction_kind` to:

```text
received
refunded
applied
```

Add indexes:

```text
security_deposit_id
transaction_kind
occurred_on
party_id
charge_id
voided_at
superseded_by_id
```

Add:

```text
UNIQUE(superseded_by_id)
WHERE superseded_by_id IS NOT NULL
```

Posted transactions must not be hard-deleted. The PRD explicitly includes security-deposit transactions in the financial-record deletion policy. 

---

# 10. Kind-specific semantics

## `received`

Require:

```text
party_id present
charge_id nil
```

`party` means:

```text
who supplied the deposit money
```

It need not be a current tenant.

Like ordinary Receipt payer identity, a parent, guarantor, employer, or organization may legitimately supply funds.

## `refunded`

Require:

```text
party_id present
charge_id nil
```

Here `party` means:

```text
who received the refund
```

It need not necessarily be the original contributor.

## `applied`

Require:

```text
charge_id present
party_id nil
```

The Tenancy/Charge identifies whose running account is settled. There is no meaningful payer Party for the application itself.

---

# 11. Ownership invariants

Every referenced object must resolve to the same user:

```text
SecurityDeposit.tenancy.accounting_user
party.user
charge.tenancy.accounting_user
```

For application also require:

```text
charge.tenancy_id ==
security_deposit.tenancy_id
```

Put these validations on the model as defense in depth, not only specialized services.

---

# 12. Transaction dates represent actual events

Require:

```text
occurred_on <= Date.current
```

Do not use `SecurityDepositTransaction` to schedule future refunds or applications.

A future planned event is not yet a financial event and should not affect ledger balances.

---

# 13. Posted transaction immutability

Once `posted_at` exists, ordinary updates cannot change:

```text
security_deposit_id
transaction_kind
amount_cents
occurred_on
party_id
charge_id
external_reference
memo
posted_at
voided_at
superseded_by_id
```

Lifecycle fields may only be changed through controlled correction/void services.

Follow the same pattern already established for Receipt, where posted financial fields and lifecycle fields are protected from ordinary model mutation. 

---

# 14. Accounting posting service

Create:

```text
SecurityDepositTransactions::PostService
```

Use:

```text
source: SecurityDepositTransaction
```

with event types already named by the PRD:

```text
deposit_received
deposit_refunded
deposit_applied
``` 


---

# 15. Received posting

For `$2,000`:

```text
Dr Cash                      +200000
Cr Security Deposits Held    -200000
```

Both postings carry:

```text
property
rentable_unit
tenancy
party
```

The Party is the contributor.

It must not touch:

```text
Tenant Receivable
Rental Income
``` 


---

# 16. Refunded posting

For `$500`:

```text
Dr Security Deposits Held     +50000
Cr Cash                       -50000
```

Dimensions:

```text
property
rentable_unit
tenancy
party = refund recipient
```

A refund is a **new real-world cash event**, not a reversal of the original deposit receipt. 

This distinction matters.

---

# 17. Applied posting

For `$500` applied against an existing Charge:

```text
Dr Security Deposits Held    +50000
Cr Tenant Receivable         -50000
```

Dimensions:

```text
property
rentable_unit
tenancy
party = nil
```

No income account participates.

The selected Charge already recognized whatever income/reimbursement classification generated the obligation. 

---

# 18. Create an authoritative held-liability query

Create:

```text
Accounting::SecurityDepositBalanceQuery
```

The result must come from the ledger, not by summing transaction rows.

Conceptually:

```text
held_cents =
  -SUM(
    postings.amount_cents
    where account = security_deposits_held
      and tenancy = target tenancy
      and journal_entry.occurred_on <= as_of
  )
```

The sign inversion is because a liability normally carries a credit balance under Yanushi's signed-posting convention.

Return:

```text
positive = money currently held
zero     = no liability
```

This follows the same architecture already used by tenancy balance, which reads postings rather than reconstructing state from Charges and Receipts. 

---

# 19. SecurityDeposit helpers

Expose:

```ruby
def held_cents(as_of: Date.current)
def held_amount(as_of: Date.current)
def remaining_required_cents(as_of: Date.current)
```

where:

```text
remaining_required =
  max(required_amount_cents - held_cents, 0)
```

Do not store any of these values.

---

# 20. Do not cap receipts to the contractual requirement

Permit:

```text
required      $2,000
held          $2,050
```

Accounting should faithfully represent what was actually received as a refundable liability.

The UI can display:

```text
Overfunded by $50
```

but must not silently turn excess deposit money into rent, income, or Tenant Receivable.

---

# 21. One aggregate lock controls liability mutations

All operations that change held security-deposit liability must first acquire:

```text
SecurityDeposit row lock
```

That includes:

```text
receive
refund
apply
void transaction
correct transaction
```

The security-deposit aggregate row is the concurrency serialization boundary.

This directly addresses the PRD's requirement that security-deposit application be protected against concurrent over-application. 

---

# 22. Do not validate only the current total

A stronger invariant is required than:

```text
current held >= 0
```

Backdated transactions can otherwise make an earlier liability period negative.

Example:

```text
Jan 1  receive  $1,000
Jan 10 refund   $1,000
Jan 20 receive    $500

then insert:
Jan 5  refund     $500
```

Current held ends at `$0`, but from January 10 to January 19 the historical liability would be `-$500`.

That must be rejected.

---

# 23. Add a deposit-liability timeline validator

Create something like:

```text
SecurityDeposits::LiabilityTimeline
```

or:

```text
SecurityDeposits::ValidateBalanceService
```

Under the SecurityDeposit lock:

1. load all active posted deposit transactions;
2. apply the proposed create/void/correction change in memory;
3. group liability deltas by `occurred_on`;
4. walk dates chronologically;
5. require cumulative held amount to remain `>= 0` at every date.

Domain liability delta:

```text
received   +amount
refunded   -amount
applied    -amount
```

Use this for **validation only**.

Actual displayed/reportable held balance still comes from the ledger.

---

# 24. Received service

Create:

```text
SecurityDepositTransactions::ReceiveService
```

Inputs:

```text
security_deposit
party
amount
occurred_on
external_reference optional
memo optional
```

Inside one transaction:

1. lock SecurityDeposit;
2. validate Party ownership;
3. parse amount/date;
4. run liability timeline validation;
5. create transaction;
6. post it;
7. set `posted_at`;
8. commit.

Do not route this through `Receipts::CreateService`.

---

# 25. Refund service

Create:

```text
SecurityDepositTransactions::RefundService
```

Inputs:

```text
security_deposit
party
amount
occurred_on
external_reference optional
memo optional
```

Inside the SecurityDeposit lock:

```text
proposed refund must preserve
nonnegative held liability
for every accounting date
```

Then post:

```text
Dr Deposit Liability
Cr Cash
```

---

# 26. Application semantics under a running account

Yanushi deliberately does not allocate ordinary Receipts to individual Charges. The tenancy balance is simply the Tenant Receivable posting balance. 

Therefore do **not** invent a concept such as:

```text
charge.unpaid_balance
```

unless it is specifically deposit-application-derived.

For a deposit application to Charge X, cap by three independently knowable values:

```text
1. deposit liability available
2. remaining deposit amount ever applied to Charge X
3. positive Tenant Receivable balance as of application date
```

---

# 27. Charge-specific deposit application capacity

Define:

```text
already_applied_to_charge =
  SUM(active deposit-applied transactions for charge)

remaining_charge_application =
  charge.amount_cents - already_applied_to_charge
```

This does **not** claim to know whether ordinary Receipts paid that Charge.

It merely prevents security-deposit applications themselves from exceeding the Charge that supplies their semantic reason.

---

# 28. Tenant-account application capacity

Use:

```text
tenancy.balance_cents(as_of: occurred_on)
```

The current balance query already supports as-of dates from Tenant Receivable postings. 

Require:

```text
tenant_receivable_balance > 0
```

and cap application by that positive amount.

Do not use current-day balance for a backdated application.

---

# 29. Final application maximum

The maximum application is:

```text
min(
  deposit held available at occurred_on,
  selected Charge remaining deposit-application capacity,
  positive tenancy receivable balance at occurred_on
)
```

A requested amount greater than any of those fails.

Do not silently truncate it.

---

# 30. Apply service

Create:

```text
SecurityDepositTransactions::ApplyService
```

Inputs:

```text
security_deposit
charge
amount
occurred_on
memo optional
```

Require Charge to be:

```text
persisted
posted
active
same tenancy
```

A voided or superseded Charge cannot receive a new deposit application.

The current Charge model already distinguishes active/voided/superseded lifecycle states. 

---

# 31. Lock order for application

Application needs both aggregate and Charge stability.

Use:

```text
SecurityDeposit
    ↓
Charge
```

as the lock order.

Inside those locks:

1. reload both;
2. require Charge active;
3. re-evaluate held liability;
4. re-evaluate Tenant Receivable;
5. re-evaluate prior applications to the Charge;
6. create/post application.

---

# 32. Integrate deposit applications with Charge lifecycle

Once a Charge has an active deposit application, its financial history cannot be independently voided or corrected without handling that application.

Add:

```ruby
Charge
  has_many :security_deposit_applications,
    -> { ... transaction_kind applied ... },
    dependent: :restrict_with_error
```

Then:

```text
Charges::VoidService
Charges::CorrectService
```

must reject an active Charge that has active security-deposit applications.

Tell the user:

```text
Reverse/correct the deposit application first.
```

Otherwise Yanushi could leave an application pointing to a voided Charge and create an unexplained Tenant Receivable credit.

---

# 33. Preserve global lock ordering

Charge lifecycle already has special locking around reimbursement Expenses.

Once deposit application exists, document a global order such as:

```text
Expense(s), stable ID order
    ↓
SecurityDeposit(s), stable ID order
    ↓
Charge
```

Then make all affected lifecycle services follow it.

Avoid:

```text
Charge -> SecurityDeposit
```

anywhere.

This prevents the new aggregate dependency from creating a lock-order cycle with the reimbursement lifecycle work completed in Milestone 5.

---

# 34. Integrate with Expense correction

`Expenses::CorrectService` currently restates its reimbursement Charges.

Before correcting an Expense, if any affected reimbursement Charge has an active security-deposit application:

```text
reject correction
```

with guidance to reverse/correct the deposit application first.

Do not automatically guess what should happen to applied deposit money when the underlying reimbursement Charge is being restated.

That policy should remain explicit.

---

# 35. Transaction void semantics

For `SecurityDepositTransaction`, **void means the transaction was recorded in error**.

That is different from:

```text
deposit refund
```

which has its own `refunded` transaction kind.

Therefore a deposit-transaction void should always reverse on:

```text
original transaction.occurred_on
```

Example:

```text
Jan 1 erroneous $2,000 deposit receipt
discovered Feb 1

void:
  reverse Jan 1
```

Do not date it February 1.

If money actually leaves on February 1, record a `refunded` transaction instead.

---

# 36. Void service

Create:

```text
SecurityDepositTransactions::VoidService
```

Inside one transaction:

1. lock SecurityDeposit;
2. lock transaction;
3. reject superseded transaction;
4. if already voided:
   - identical retry => existing reversal;
5. simulate removal through liability timeline validator;
6. reject if removal would make historical held liability negative;
7. reverse original JournalEntry on original `occurred_on`;
8. set `voided_at`;
9. commit.

A received transaction with later refunds/applications may therefore be impossible to void until those later withdrawals are dealt with.

That is correct.

---

# 37. Transaction correction

Create:

```text
SecurityDepositTransactions::CorrectService
```

Correction:

```text
original transaction
original JournalEntry
reversal
replacement transaction
replacement JournalEntry
```

and:

```text
original.superseded_by = replacement
```

Do not edit a posted transaction in place.

This follows the architecture-wide posted-history rule. 

---

# 38. Keep correction within the same SecurityDeposit

For Milestone 6, do **not** allow:

```text
SecurityDeposit A transaction
  corrected into
SecurityDeposit B
```

If the wrong tenancy/deposit was selected:

```text
void original
create correct transaction on target deposit
```

This keeps correction concurrency local to one aggregate.

---

# 39. Same-kind correction

For the first implementation, require the replacement to retain the same:

```text
transaction_kind
```

Allow correction of:

```text
amount
occurred_on
party
charge for applied transaction
external_reference
memo
```

If the original kind itself was wrong, use:

```text
void + new correct transaction
```

This keeps capacity and liability validation understandable.

---

# 40. Correction atomicity

Within the SecurityDeposit lock:

1. lock original transaction;
2. handle existing replacement idempotently;
3. validate replacement inputs;
4. simulate the replacement through the full liability timeline;
5. reverse original at original date;
6. create/post replacement;
7. set original `voided_at`;
8. link `superseded_by`;
9. commit.

Any failure:

```text
original remains active
no reversal remains
no replacement remains
```

---

# 41. Application correction

If correcting an `applied` transaction, re-run all application constraints for the replacement:

```text
target Charge active
same tenancy
held liability sufficient
positive A/R sufficient
charge-specific application capacity sufficient
```

When calculating capacity, exclude the original application being replaced.

---

# 42. Deposit query remains independent of required amount

Do not define:

```text
held = required - refunded
```

The two concepts are independent:

```text
required amount
    contractual expectation

held amount
    accounting liability
```

Examples:

```text
required  $2,000
held      $1,000
status    partially funded
```

```text
required  $2,000
held      $2,000
status    funded
```

```text
required  $2,000
held        $500
status    $1,500 was refunded/applied
```

---

# 43. Add Tenancy associations

Add:

```ruby
has_one :security_deposit,
  dependent: :restrict_with_error
```

and convenient transaction access if useful.

Update `financial_history?` so deposit transactions count explicitly.

Accounting postings already provide a safety net, but direct domain history should also be recognized. The current method presently considers Charges, Receipts, and accounting postings. 

---

# 44. Party associations

Add:

```ruby
has_many :security_deposit_transactions,
  dependent: :restrict_with_error
```

A Party referenced as deposit contributor/refund recipient must not be deleted out from under posted financial history.

---

# 45. Security deposit setup service

Create:

```text
SecurityDeposits::CreateService
```

Inputs:

```text
tenancy
required_amount
due_on
```

Acquire Tenancy lock before creating the unique aggregate to make duplicate concurrent creation deterministic.

Return an existing equivalent aggregate idempotently if appropriate, otherwise fail on conflict.

---

# 46. Requirement update service

Create:

```text
SecurityDeposits::UpdateService
```

Permit updating:

```text
required_amount
due_on
```

only if:

```text
transactions.none?
```

Do the check under the SecurityDeposit lock.

Do not expose generic `update` directly from the controller.

---

# 47. Routes

Suggested shape:

```ruby
resources :tenancies do
  resource :security_deposit, only: %i[new create show edit update] do
    post :receive
    post :refund
    post :apply
  end
end

resources :security_deposit_transactions, only: %i[show] do
  member do
    get :correction
    post :correct
    post :void
  end
end
```

A singular nested `security_deposit` matches the one-per-tenancy model.

---

# 48. Keep nested Tenancy authoritative

For:

```text
/tenancies/:tenancy_id/security_deposit
```

resolve the Tenancy using:

```ruby
authenticated_user.tenancies.find(params[:tenancy_id])
```

Do not allow a body `tenancy_id` to override the route.

Apply the same route-binding discipline established for Receipts and Expenses.

---

# 49. Tenancy page

The current Tenancy page has separate Charges, Payments/Receipts, and account-balance sections. Security deposit deserves its own card rather than being added to Payments & Receipts. 

Show:

```text
Security Deposit

Required          $2,000
Due               Jan 1, 2027
Currently Held    $1,500
Remaining         $500
```

Status examples:

```text
Not funded
Partially funded
Funded
Overfunded
No amount held
```

---

# 50. Deposit actions

On the Security Deposit card:

```text
Record Deposit
Refund Deposit
Apply Deposit
View History
```

Only enable:

```text
Refund
Apply
```

when held liability is positive.

Disable `Apply` when:

```text
tenancy balance <= 0
```

but keep server validation authoritative.

---

# 51. Record Deposit form

Fields:

```text
Contributor
Amount
Received on
External reference
Memo
```

Contributor picker:

```text
all user-owned Parties
```

not only Tenancy participants.

Do not reuse the ordinary Receipt form or route.

---

# 52. Refund form

Fields:

```text
Recipient
Amount
Refunded on
External reference
Memo
```

Display:

```text
Currently held: $X
Maximum refund: $X
```

Reject excess server-side.

---

# 53. Apply form

Show:

```text
Currently held
Current tenancy balance
```

Select from:

```text
active posted Charges
for this Tenancy
```

For each option display something like:

```text
Rent — Aug 2026 — $2,000
Damage reimbursement — $500
Late fee — $50
```

After selecting a Charge, show the calculated maximum applicable amount.

---

# 54. Do not pretend the selected Charge has ordinary-payment settlement state

Avoid UI copy such as:

```text
Charge unpaid balance
```

because ordinary Receipts are not allocated.

Instead say:

```text
Maximum deposit application to this charge
```

which is based on:

```text
charge amount
minus prior deposit applications
```

plus the tenancy-level A/R cap.

---

# 55. Deposit history

Display every transaction:

```text
Date
Kind
Party / Charge
Amount
Reference
Status
```

Examples:

```text
Jan 1   Received   Alice            +$2,000
Aug 1   Applied    Damage Charge      -$500
Aug 15  Refunded   Alice              -$500
```

Use liability-oriented presentation rather than debit/credit terminology.

---

# 56. Corrected and voided transaction presentation

Use the lifecycle precedence already established elsewhere:

```text
superseded -> Corrected
voided     -> Voided
posted     -> Active
```

Show links:

```text
original -> replacement
replacement -> original
```

Do not repeat the corrected-vs-voided UI bug previously encountered with Charges and Expenses.

---

# 57. Liability reporting

At minimum add:

```text
Tenancy:
  Required deposit
  Deposit held
```

and:

```text
Property:
  Security deposits held
```

Property deposit liability should come from the ledger:

```text
security_deposits_held postings
filtered by property
```

not by summing `SecurityDepositTransaction` rows.

The PRD explicitly requires security-deposit liability reporting in Milestone 6, while the larger ledger/reporting rewrite remains Milestone 8. 

---

# 58. Interim property financial timeline

The existing full ledger projection is not replaced until Milestone 8.

For the current interim property activity query, add domain rows for:

```text
Security deposit received
Security deposit refund
Deposit applied
```

with lifecycle status.

Do not rewrite the whole property ledger early.

The PRD's eventual property activity vocabulary explicitly includes these deposit events. 

---

# 59. Schedule E must remain unchanged by deposits

Add explicit regression coverage proving:

```text
deposit received
deposit refunded
deposit applied
```

do not change:

```text
Schedule E rents received
```

A refundable deposit is not an ordinary rent receipt. 

This should happen naturally because deposits never become `Receipt`, but pin it with tests.

---

# 60. Tenant balance acceptance

Receive:

```text
Security deposit       $2,000
```

Expected:

```text
Cash                    +$2,000
Deposit liability       +$2,000

Tenant Receivable       unchanged
Tenancy balance         unchanged
```

This is a core PRD acceptance criterion. 

---

# 61. Refund acceptance

Given:

```text
held deposit            $2,000
```

Refund:

```text
$750
```

Expected:

```text
Deposit held            $1,250
Tenant Receivable       unchanged
Cash                    decreased $750
```

A second refund over `$1,250` fails.

---

# 62. Application acceptance

Given:

```text
Damage Charge           $500
Tenant balance          $500
Deposit held          $2,000
```

Apply:

```text
$500
```

Expected:

```text
Tenant Receivable         $0
Deposit held            $1,500
Cash                    unchanged
Income                  unchanged
```

This directly pins the PRD's application semantics. 

---

# 63. Partial application

Given:

```text
Charge                  $500
Tenant balance          $500
Deposit held            $300
```

Maximum application:

```text
$300
```

After application:

```text
Tenant balance          $200
Deposit held              $0
```

---

# 64. Account-credit protection

Given:

```text
Tenant balance          $100
Deposit held          $2,000
Charge selected         $500
```

Attempt:

```text
apply $500
```

must fail.

Maximum application is:

```text
$100
```

Do not create a deposit-derived tenant credit unless explicitly supported later. The PRD requires the application not exceed the relevant tenant-account amount being settled. 

---

# 65. Multiple applications to one Charge

Given:

```text
Charge amount           $500

Application 1           $300
```

Maximum further deposit application to that Charge:

```text
$200
```

even if the tenancy has other outstanding Charges.

---

# 66. Running-account limitation test

Explicitly document/test:

```text
Charge A                $500
Charge B                $500
Receipt                 $500
Tenant balance          $500
```

Yanushi does not know which Charge the ordinary Receipt settled.

A deposit may still be applied against an active Charge subject to:

```text
selected-charge deposit cap
+
overall Tenant Receivable cap
```

Do not introduce receipt allocation merely to make this distinction more precise.

---

# 67. Cross-tenancy isolation

Security Deposit for:

```text
Unit A Tenancy
```

must never:

- apply to Unit B Charge;
- affect Unit B Tenant Receivable;
- appear as Unit B deposit liability.

This should be protected at both model and service layers.

---

# 68. Concurrent refund tests

With:

```text
held = $2,000
```

two concurrent:

```text
refund $1,500
```

requests must result in:

```text
one success
one failure
held >= 0
```

Never:

```text
held = -$1,000
```

---

# 69. Concurrent application tests

With:

```text
held = $500
A/R  = $500
```

two concurrent:

```text
apply $500
```

requests must create only one valid application.

The SecurityDeposit lock is the serialization boundary.

---

# 70. Concurrent refund vs application

Given:

```text
held = $500
```

race:

```text
refund $500
vs
apply $500
```

Exactly one may consume the liability.

The other must fail after reloading under the aggregate lock.

---

# 71. Backdated history tests

Test:

```text
Jan 1 receive $1,000
Jan 10 refund $1,000
Jan 20 receive $500
```

Then attempt:

```text
Jan 5 refund $500
```

Reject because it would make the historical deposit liability negative on January 10 even though today's final held balance would be zero.

This pins the timeline validator rather than merely current-total validation.

---

# 72. Void-received dependency

Given:

```text
Jan 1 receive $2,000
Feb 1 refund  $1,000
```

Trying to void the January receipt must fail if removing it would make February liability negative.

After the refund is voided:

```text
void received
```

may succeed.

---

# 73. Charge lifecycle integration tests

Given active:

```text
SecurityDepositTransaction(applied)
    -> Charge
```

verify:

```text
Charges::VoidService
    rejected

Charges::CorrectService
    rejected
```

After voiding/correcting the deposit application:

```text
Charge lifecycle operation permitted
```

This prevents orphaned settlement semantics.

---

# 74. Expense/reimbursement integration test

Given:

```text
Expense
  -> reimbursement Charge
      -> active deposit application
```

attempt:

```text
Correct Expense
```

must fail until the deposit application is reversed/corrected.

This protects the Milestone 5 automatic reimbursement-restatement workflow.

---

# 75. Void transaction tests

For every kind:

```text
received
refunded
applied
```

verify:

- original remains;
- original JournalEntry remains;
- reversal exists;
- reversal uses original `occurred_on`;
- original receives `voided_at`;
- transaction cannot be hard-deleted;
- identical retry is idempotent;
- conflicting retry fails if applicable.

---

# 76. Correction tests

For each kind, test a straightforward correction.

Example receive correction:

```text
original:
Jan 1, $2,000 from Alice

replacement:
Jan 1, $2,100 from Alice
```

Expected net liability:

```text
$2,100
```

with full original/reversal/replacement audit chain.

---

# 77. Correction must preserve nonnegative history

Example:

```text
Jan 1 received $2,000
Feb 1 refunded $1,500
```

Attempt to correct January receipt to:

```text
$1,000
```

must fail because the resulting February liability would be negative.

No reversal or replacement may remain after failure.

---

# 78. Correction retry semantics

Identical repeated correction:

```text
same replacement returned
one reversal
one replacement
```

Different repeated correction:

```text
:idempotency_conflict
```

Follow the same strong lifecycle idempotency standard established in prior milestones.

---

# 79. Source-event posting identity

Verify:

```text
source_type = SecurityDepositTransaction
```

and:

```text
received -> deposit_received
refunded -> deposit_refunded
applied  -> deposit_applied
```

The ledger's unique source-event constraint should prevent the same transaction event from posting twice. 

---

# 80. Money boundaries

Use integer cents internally.

Public HTTP forms accept:

```text
amount
required_amount
```

in dollars.

Do **not** permit:

```text
amount_cents
required_amount_cents
```

through public strong parameters.

The internal services may accept cents only when the argument is an actual `Integer`.

Carry forward the boundary rule established during Milestone 5.

---

# 81. Seeds

Seed security deposits through real services:

```text
SecurityDeposits::CreateService
SecurityDepositTransactions::ReceiveService
SecurityDepositTransactions::RefundService
SecurityDepositTransactions::ApplyService
```

Do not manually construct JournalEntries.

---

# 82. Factories

Add:

```text
:security_deposit
:security_deposit_transaction
```

traits:

```text
:received
:refunded
:applied
:voided
:corrected
```

For financially-real test setup, prefer the domain services so the ledger is present.

Use raw factories only for isolated validation tests.

---

# 83. RBS / Steep

Add signatures for:

```text
SecurityDeposit
SecurityDepositTransaction

SecurityDeposits::CreateService
SecurityDeposits::UpdateService
SecurityDeposits::LiabilityTimeline

SecurityDepositTransactions::PostService
SecurityDepositTransactions::ReceiveService
SecurityDepositTransactions::RefundService
SecurityDepositTransactions::ApplyService
SecurityDepositTransactions::VoidService
SecurityDepositTransactions::CorrectService

Accounting::SecurityDepositBalanceQuery
```

Update:

```text
Tenancy
Party
Charge
Charges::VoidService
Charges::CorrectService
Expenses::CorrectService
```

Regenerate Rails signatures and keep broad Steep coverage.

---

# 84. Documentation

Add:

```text
documentation/double_entry_accounting/implementation_plan_milestone_6.md
```

Document explicitly:

- requirement versus held liability;
- deposit versus Receipt;
- liability posting rules;
- refund versus reversal;
- application semantics;
- no duplicate income recognition;
- application under running-account semantics;
- historical nonnegative-liability invariant;
- aggregate locking;
- interaction with Charge correction;
- transaction correction history.

The project-wide architecture documentation already calls for explicit security-deposit semantics. 

---

# 85. Stale-assumption searches

Before finalizing:

```bash
rg -n \
  'security_deposit|security_deposits_held|deposit_received|deposit_refunded|deposit_applied' \
  app config db spec sig
```

Then ensure ordinary Receipt code has not grown deposit branching:

```bash
rg -n \
  'security.deposit|deposit' \
  app/models/receipt.rb \
  app/services/receipts \
  app/controllers/receipts_controller.rb
```

Expected:

```text
no security-deposit behavior in Receipt
```

---

# 86. Verify service-owned persistence

Search:

```bash
rg -n \
  'SecurityDepositTransaction\.(new|create|create!)|security_deposit_transactions\.(build|create|create!)' \
  app
```

Every financially-real production transaction should flow through the specialized domain services.

Likewise verify no direct JournalEntry/Posting creation escaped the accounting boundary.

---

# 87. Clean database verification

Since the project still permits destructive schema development:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate
```

Verify:

```text
security_deposits
security_deposit_transactions
```

constraints and FKs.

No Receipt schema change should be necessary.

---

# 88. Manual smoke test

Using a clean database:

1. Create Property/Unit/Tenancy.
2. Set a `$2,000` security-deposit requirement.
3. Confirm Tenant Receivable is unchanged.
4. Record `$1,000` from Tenant A.
5. Confirm held = `$1,000`.
6. Record `$1,000` from Tenant B/third party.
7. Confirm held = `$2,000`.
8. Confirm tenancy balance is still unchanged.
9. Create a `$500` damage/reimbursement Charge.
10. Apply `$300` deposit.
11. Confirm held = `$1,700`.
12. Confirm tenancy balance decreases `$300`.
13. Apply remaining `$200`.
14. Confirm selected Charge cannot receive another deposit application.
15. Refund `$500`.
16. Confirm held = `$1,000`.
17. Try an excessive refund.
18. Confirm rejection.
19. Try applying deposit to another Tenancy's Charge.
20. Confirm rejection.
21. Try voiding a Charge with an active application.
22. Confirm rejection.
23. Void the application.
24. Confirm Charge lifecycle becomes available again.
25. Correct a deposit receipt.
26. Confirm original/reversal/replacement audit history.
27. Open interim Schedule E.
28. Confirm deposit money is absent from rents received.

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

Include real threaded coverage for the aggregate-lock scenarios rather than mocked lock calls.

---

# 90. Suggested commit boundaries

**Commit 1: Add SecurityDeposit domain**

```text
security_deposits
security_deposit_transactions
models
constraints
associations
factories
```

**Commit 2: Add liability accounting**

```text
PostService
SecurityDepositBalanceQuery
received/refunded posting
accounting specs
```

**Commit 3: Add receive/refund workflows**

```text
CreateService
UpdateService
ReceiveService
RefundService
tenancy UI
routes/controllers
```

**Commit 4: Add deposit application**

```text
ApplyService
Charge association
application capacity
A/R integration
cross-tenancy validation
```

**Commit 5: Add lifecycle integration**

```text
deposit transaction void/correction
Charge void/correct guards
Expense correction guard
lock-order documentation
concurrency specs
```

**Commit 6: Reporting/UI compatibility**

```text
held-liability displays
property deposit liability
interim financial timeline
Schedule E regression
history views
```

**Commit 7: Typing/docs/cleanup**

```text
RBS
Steep
documentation
seeds
stale searches
full quality gate
```

---

# 91. Milestone 6 acceptance checklist

### Domain

- [ ] One `SecurityDeposit` per Tenancy.
- [ ] Requirement uses integer cents.
- [ ] Held amount is not stored.
- [ ] Deposit transactions use integer cents.
- [ ] Received/refunded/applied kinds exist.
- [ ] Posted transactions are immutable.
- [ ] Posted transactions cannot be deleted.
- [ ] Deposit transactions never become Receipts.

### Accounting

- [ ] Received posts Dr Cash / Cr Deposit Liability.
- [ ] Refund posts Dr Deposit Liability / Cr Cash.
- [ ] Application posts Dr Deposit Liability / Cr Tenant Receivable.
- [ ] No deposit event directly touches income.
- [ ] Deposit receipt does not affect Tenant Receivable.
- [ ] Deposit receipt does not affect ordinary rent-received reporting.
- [ ] Held liability is derived from postings.

### Liability integrity

- [ ] Held liability can never be negative.
- [ ] Historical held liability can never be negative.
- [ ] Refunds serialize under the SecurityDeposit lock.
- [ ] Applications serialize under the SecurityDeposit lock.
- [ ] Backdated transactions cannot create historical negative periods.
- [ ] Voiding/correcting received funds respects later withdrawals.

### Applications

- [ ] Application requires an active posted Charge.
- [ ] Charge must belong to the same Tenancy.
- [ ] Application cannot exceed held liability.
- [ ] Application cannot exceed positive Tenant Receivable.
- [ ] Deposit applications to one Charge cannot exceed that Charge amount.
- [ ] Ordinary Receipt allocations remain unnecessary.
- [ ] Application never recognizes income twice.

### Lifecycle integration

- [ ] Active deposit application blocks Charge void.
- [ ] Active deposit application blocks Charge correction.
- [ ] Active applied reimbursement blocks Expense correction indirectly.
- [ ] Deposit application must be reversed/corrected first.
- [ ] Global lock ordering is documented.
- [ ] No lock-order cycle is introduced.

### Corrections

- [ ] Void means bookkeeping error.
- [ ] Refund means actual cash returned.
- [ ] Void reverses on original date.
- [ ] Correction preserves original event.
- [ ] Correction creates reversal.
- [ ] Correction creates replacement.
- [ ] Equivalent retry is idempotent.
- [ ] Conflicting retry fails.

### UI

- [ ] Tenancy shows deposit required.
- [ ] Tenancy shows deposit held.
- [ ] Tenancy shows remaining requirement.
- [ ] Deposit has its own card, separate from Receipts.
- [ ] Record Deposit works.
- [ ] Refund works.
- [ ] Apply to Charge works.
- [ ] Transaction history works.
- [ ] Corrected/voided states are distinguishable.

### Core PRD acceptance

For:

```text
Receive deposit    $2,000
```

- [ ] Cash increases `$2,000`.
- [ ] Deposit liability increases `$2,000`.
- [ ] Tenant Receivable unchanged.

For:

```text
Refund             $2,000
```

- [ ] Cash decreases `$2,000`.
- [ ] Deposit liability returns to zero.

For:

```text
Damage Charge        $500
Deposit applied      $500
```

- [ ] Tenant Receivable decreases `$500`.
- [ ] Deposit liability decreases `$500`.
- [ ] No additional income is recognized.

Those are the exact behavioral outcomes the PRD uses to define Milestone 6 completion. 

The most important implementation detail is the **SecurityDeposit aggregate lock plus historical liability validator**. Checking only today's held amount is not enough once backdated refunds, applications, voids, and corrections exist. And the most important cross-milestone integration is making active deposit applications block independent Charge correction: once deposit money has settled a Charge, those two immutable histories have to be unwound in the right order rather than allowed to drift apart.
