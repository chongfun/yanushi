# Implementation Plan: Milestone 1 — Core Rental Domain

## Objective

Implement Milestone 1 of the Rental Domain and Double-Entry Accounting Architecture.

At the end of this milestone, Yanushi must use these core concepts throughout the running application:

```text
User
├── Property
│   └── RentableUnit
│       └── Tenancy
│           ├── TenancyParty ── Party
│           └── RentTerm
│
└── Party
    └── PartyAlias
```

This milestone establishes the rental-domain identities and relationships that later accounting milestones will build on.

Do **not** implement the double-entry ledger, `Charge`, `Receipt`, `SecurityDeposit`, or tax redesign in this milestone.

Existing financial models such as `ScheduledRent`, `TenantPayment`, `TenantCharge`, `Expense`, and payment ingestion may remain temporarily, but they must refer to the new core identities rather than keeping `RentalProperty`, `Lease`, or `Tenant` alive as parallel models.

There is no production data to preserve. Prefer a clean schema and application model over compatibility/backfill machinery.

---

# 1. Read before modifying

Read the architecture PRD and inspect the current implementations of:

```text
app/models/rental_property.rb
app/models/lease.rb
app/models/lease_tenant.rb
app/models/tenant.rb
app/models/tenant_alias.rb
app/models/user.rb

app/controllers/rental_properties_controller.rb
app/controllers/leases_controller.rb
app/controllers/tenants_controller.rb
app/controllers/dashboards_controller.rb

app/models/payment_ingestion.rb
app/models/expense.rb

config/routes.rb
db/schema.rb
spec/factories.rb
Steepfile
sig/README.md
```

The existing model currently has:

```text
RentalProperty -> Lease -> LeaseTenant -> Tenant
```

with rent amount, lease type, and security deposit stored directly on `Lease`. `RentalProperty.property_type` also contains both physical-property and tax-oriented values.

The current controllers, routes, and dashboard are also explicitly organized around `rental_properties`, `leases`, and `tenants`.

---

# 2. Establish a clean baseline

Before changing code:

```bash
git status --short
bundle exec rspec
bundle exec rbs validate
bundle exec steep check
bin/rubocop
```

Record any pre-existing failures.

Do not treat a pre-existing failure as introduced by this milestone, but do not add new failures.

Then inventory every dependency on the old vocabulary:

```bash
rg -n \
  '\bRentalProperty\b|\brental_property\b|\bRentalProperties::|\bLease\b|\blease_id\b|\bLeases::|\bLeaseTenant\b|\bTenant\b|\btenant_id\b|\bannual_rental_amount\b|\bproperty_type\b|\blease_type\b|\bsecurity_deposit\b' \
  app config db spec sig documentation
```

Keep this search available throughout the implementation. It is the main cleanup check at the end.

---

# 3. Make the schema transition in one coherent migration

Do not introduce dual-write columns or temporary compatibility tables.

Use one migration for the core-domain cutover.

Prefer renaming tables that represent the same conceptual identity and then reshaping them.

## 3.1 Rename core tables

Rename:

```text
rental_properties -> properties
tenants           -> parties
tenant_aliases    -> party_aliases
leases            -> tenancies
lease_tenants     -> tenancy_parties
```

Rename corresponding foreign-key columns:

```text
party_aliases.tenant_id
    -> party_id

tenancy_parties.lease_id
    -> tenancy_id

tenancy_parties.tenant_id
    -> party_id
```

Do not retain old table aliases.

---

# 4. Define the final Milestone 1 schema

## 4.1 properties

The resulting table should contain approximately:

```text
id
user_id              NOT NULL
address               NOT NULL
asset_type            NOT NULL
square_footage
created_at
updated_at
```

Use a string-backed `asset_type`.

Supported values:

```text
single_family
multifamily
commercial
mixed_use
land
other
```

Remove the old integer `property_type`.

Do not carry forward:

```text
vacation_or_short_term_rental
royalties
self_rental
```

as physical asset types.

Add indexes and the existing user foreign key as appropriate.

---

## 4.2 rentable_units

Create:

```text
rentable_units
```

with:

```text
id
property_id           NOT NULL
name                  NOT NULL
unit_identifier
square_footage
active                NOT NULL DEFAULT true
created_at
updated_at
```

Add:

```text
FK rentable_units.property_id -> properties.id
index(property_id)
```

If `unit_identifier` is present, require it to be unique within the property, case-insensitively if practical.

Do not require every unit to have an identifier. A single-family house's implicit unit may simply be named `Main Unit`.

---

## 4.3 parties

Reshape the renamed `parties` table to:

```text
id
user_id               NOT NULL
party_type             NOT NULL
display_name           NOT NULL
email_address
phone_number
mailing_address
created_at
updated_at
```

Rename:

```text
name -> display_name
```

Add string-backed:

```text
party_type
```

with:

```text
individual
organization
```

Default new form submissions to `individual`, but keep the domain model explicit.

---

## 4.4 party_aliases

The renamed `party_aliases` table should contain:

```text
id
party_id              NOT NULL
alias_name            NOT NULL
created_at
updated_at
```

Preserve case-insensitive uniqueness within a party.

Do **not** require aliases to be globally unique across all parties. Ambiguous imported identities can be handled by the matching layer rather than lying about uniqueness here.

---

## 4.5 tenancies

Reshape the renamed `tenancies` table to:

```text
id
rentable_unit_id      NOT NULL
commencement_date     NOT NULL
termination_date
agreement_type        NOT NULL
late_period_days      NOT NULL DEFAULT 0
created_at
updated_at
```

Remove:

```text
rental_property_id
annual_rental_amount
security_deposit
lease_type
```

Use string-backed `agreement_type`:

```text
fixed_term
month_to_month
other
```

Do not retain a rent amount on `Tenancy`.

Do not retain the deposit requirement on `Tenancy`. Security deposits are intentionally deferred to the security-deposit milestone.

---

## 4.6 tenancy_parties

Reshape the renamed join table to:

```text
id
tenancy_id            NOT NULL
party_id              NOT NULL
role                  NOT NULL
effective_from        NOT NULL
effective_until
created_at
updated_at
```

String-backed roles:

```text
tenant
guarantor
occupant
```

Add indexes on:

```text
tenancy_id
party_id
```

and an appropriate exact-duplicate uniqueness index such as:

```text
tenancy_id, party_id, role, effective_from
```

Application-level overlap validation will handle the stronger temporal rule.

---

## 4.7 rent_terms

Create:

```text
rent_terms
```

with:

```text
id
tenancy_id            NOT NULL
amount_cents          BIGINT NOT NULL
frequency             NOT NULL
due_day               NOT NULL
effective_from        NOT NULL
effective_until
created_at
updated_at
```

Initial supported frequency:

```text
monthly
```

Use integer cents immediately.

Do not add another decimal rent amount.

Add:

```text
FK rent_terms.tenancy_id -> tenancies.id
index(tenancy_id)
```

An exact duplicate prevention index on:

```text
tenancy_id, effective_from
```

is appropriate.

---

# 5. Retarget existing financial foreign keys

Milestone 1 must not leave legacy core tables alive just so later financial models continue working.

Update the surviving legacy financial tables to point at the new core identities.

Rename:

```text
expenses.rental_property_id
    -> property_id

scheduled_rents.lease_id
    -> tenancy_id

tenant_payments.lease_id
    -> tenancy_id

tenant_charges.lease_id
    -> tenancy_id

payment_ingestions.lease_id
    -> tenancy_id

payment_ingestions.tenant_id
    -> party_id
```

Update the associated foreign keys and indexes.

`TenantPayment`, `TenantCharge`, and `ScheduledRent` are temporary financial models and may keep those class/table names until their own milestones.

What they may **not** do is continue requiring a `Lease` or `RentalProperty`.

The existing ingestion model currently references both a tenant and lease directly, so it must be mechanically retargeted to `Party` and `Tenancy` in this milestone even though ingestion itself is redesigned later.

---

# 6. Reset local databases after the destructive schema change

Because no development data must be preserved, do not write a backfill.

After the migration is complete:

```bash
bin/rails db:drop db:create db:migrate
RAILS_ENV=test bin/rails db:drop db:create db:migrate
```

Verify `db/schema.rb` contains only the intended new core tables and foreign keys.

Do not manually edit `db/schema.rb`.

---

# 7. Implement the Property model

Create:

```text
app/models/property.rb
```

Expected associations:

```ruby
belongs_to :user

has_many :rentable_units
has_many :tenancies, through: :rentable_units
has_many :expenses
```

Preserve surviving legacy financial-through associations only where the application still requires them.

Do not copy the current `RentalProperty` model wholesale: it currently owns leases directly and mixes tax classifications into `property_type`.

Add validations:

```text
address present
asset_type present and valid
square_footage positive when present
```

Add model specs for all supported `asset_type` values.

Delete:

```text
app/models/rental_property.rb
```

Do not leave:

```ruby
RentalProperty = Property
```

or another compatibility constant.

---

# 8. Implement RentableUnit

Create:

```text
app/models/rentable_unit.rb
```

Associations:

```ruby
belongs_to :property
has_many :tenancies
```

Validations:

```text
name present
square_footage > 0 when present
unit_identifier unique within property when present
```

Add a convenience method only if genuinely useful to the UI, for example:

```text
display_name
```

Avoid embedding property-type-specific behavior in this model.

---

# 9. Add automatic single-unit creation

Create a service:

```text
Properties::Create
```

Do not use an `after_create` model callback.

The service should:

1. create the property;
2. ensure at least one rentable unit exists;
3. create an implicit unit when no explicit units were supplied;
4. persist everything in one database transaction.

Default implicit unit:

```text
name: "Main Unit"
active: true
```

This may apply to all properties created without explicit units, not only `single_family`. That gives every property a usable tenancy target without encoding fragile rules about which physical asset types are "single-unit."

The UI may hide the unit abstraction when a property currently has only one unit.

Test rollback if either property or unit creation fails.

---

# 10. Implement Party and PartyAlias

Create:

```text
app/models/party.rb
app/models/party_alias.rb
```

`Party` associations:

```ruby
belongs_to :user
has_many :party_aliases
has_many :tenancy_parties
has_many :tenancies, through: :tenancy_parties
```

Retarget surviving payment-ingestion associations as required.

Port the useful alias-normalization and alias-candidate behavior from the existing `Tenant`/`TenantAlias` implementation rather than deleting it accidentally. The current code normalizes aliases and avoids duplicate aliases for the same tenant.

Update terminology from `tenant_aliases` to `party_aliases`.

Delete:

```text
app/models/tenant.rb
app/models/tenant_alias.rb
```

No `Tenant` compatibility constant.

---

# 11. Implement Tenancy

Create:

```text
app/models/tenancy.rb
```

Associations:

```ruby
belongs_to :rentable_unit

has_many :tenancy_parties
has_many :parties, through: :tenancy_parties
has_many :rent_terms
```

Temporarily add associations to surviving financial records:

```text
scheduled_rents
tenant_payments
tenant_charges
payment_ingestions
```

until those later milestones replace them.

Add convenience delegation:

```text
property
```

through the rentable unit if it improves query readability.

Do not add `property_id` redundantly to `tenancies`.

---

# 12. Tenancy validations

Implement:

```text
commencement_date is required
agreement_type is required
late_period_days >= 0
termination_date >= commencement_date when present
fixed_term requires termination_date
```

Keep or recreate:

```ruby
scope :active, ->(date = Date.current) { ... }
```

and:

```text
active?(date)
```

using the same inclusive date semantics currently used by `Lease`. The old `Lease` already models commencement/termination date activity this way.

---

# 13. Prevent overlapping tenancies on one unit

Add an application-level validation preventing date ranges for two tenancies on the same `RentableUnit` from overlapping.

Treat a `nil` termination date as open-ended.

Use inclusive date ranges.

Examples that must fail:

```text
Existing:
2026-01-01 .. 2026-12-31

New:
2026-06-01 .. 2027-05-31
```

```text
Existing:
2026-01-01 .. nil

New:
2027-01-01 .. nil
```

Examples that may succeed:

```text
Existing:
2026-01-01 .. 2026-12-31

New:
2027-01-01 .. nil
```

This is essential to making `RentableUnit` the actual occupancy boundary.

Do not prevent simultaneous tenancies on **different** units of the same property.

---

# 14. Implement TenancyParty

Create:

```text
app/models/tenancy_party.rb
```

Associations:

```ruby
belongs_to :tenancy
belongs_to :party
```

Validate:

```text
role is supported
effective_from present
effective_until >= effective_from when present
party belongs to same user as tenancy.property
effective_from >= tenancy.commencement_date
effective_until <= tenancy.termination_date when both are present
```

Port the cross-owner protection currently implemented by `LeaseTenant`, but make it traverse:

```text
tenancy -> rentable_unit -> property -> user
```

instead of:

```text
lease -> rental_property -> user
```

The existing join explicitly prevents cross-user tenant assignment, so this protection must not be lost during the rename.

---

# 15. Prevent overlapping participation records

For the same:

```text
tenancy
party
role
```

prevent overlapping effective ranges.

This permits:

```text
Alice: tenant, Jan-Jun
Alice: tenant, Jul-Dec
```

but not overlapping records for the same role.

Different roles may coexist if explicitly intended.

---

# 16. Require a tenant participant

A valid persisted tenancy must have at least one participant with:

```text
role: tenant
```

Do not implement this as a fragile `Tenancy` model validation that cannot see pending associated writes correctly.

Enforce the aggregate invariant in the tenancy create/update application service.

Model-level records may temporarily be incomplete inside the database transaction, but the transaction must not commit without a tenant participant.

---

# 17. Implement RentTerm

Create:

```text
app/models/rent_term.rb
```

Associations:

```ruby
belongs_to :tenancy
```

Validations:

```text
amount_cents > 0
frequency == monthly for now
due_day between 1 and 31
effective_from present
effective_until >= effective_from when present
effective_from >= tenancy.commencement_date
effective_until <= tenancy.termination_date when applicable
```

Define the future monthly due-date contract now:

```text
If due_day exceeds the number of days in a month,
use that month's final calendar day.
```

Do not implement rent-charge generation yet.

This only fixes the semantics future charge generation must use.

---

# 18. Prevent overlapping rent terms

Within one tenancy, rent-term effective ranges must not overlap.

Examples:

```text
Term A:
2026-01-01 .. 2026-06-30

Term B:
2026-07-01 .. nil
```

is valid.

```text
Term A:
2026-01-01 .. 2026-06-30

Term B:
2026-06-15 .. nil
```

is invalid.

A tenancy may have gaps if explicitly entered, but there may never be two simultaneously active terms.

Add:

```text
active_on(date)
```

as a query/scope only if needed by current UI or tests. Do not build future rent generation around it yet.

---

# 19. Add Tenancies::Create

Replace direct `Tenancy.new(...).save` controller orchestration with:

```text
Tenancies::Create
```

Input should contain:

```text
rentable_unit
commencement_date
termination_date
agreement_type
late_period_days

participants:
  [{ party:, role: }, ...]

initial_rent:
  amount_cents
  due_day
  effective_from
```

`frequency` defaults to `monthly`.

The service must create, inside one transaction:

1. `Tenancy`;
2. all `TenancyParty` rows;
3. one initial `RentTerm`.

For participants whose effective date is not otherwise specified, use the tenancy commencement date.

The initial rent term begins on the tenancy commencement date.

Do not create scheduled rent, journal entries, charges, or payments here.

Return a structured success/failure result following existing application conventions if one already exists.

Test full rollback when any component is invalid.

---

# 20. Add Tenancies::Update

Create a narrow update service for tenancy metadata.

Allow updates to:

```text
termination_date
agreement_type
late_period_days
```

Do not use ordinary tenancy update to change rent.

Do not silently rewrite rent terms when tenancy metadata changes.

For this milestone, treat `commencement_date` as immutable after creation. If changing it becomes necessary later, implement a dedicated correction operation that can reason about dependent effective dates.

If a new termination date would precede an existing:

```text
RentTerm.effective_until/effective_from
TenancyParty.effective_until/effective_from
```

reject the update instead of silently truncating history.

---

# 21. Add RentTerms::Change

Changing rent should create history rather than overwrite the previous amount.

Create:

```text
RentTerms::Change
```

Inputs:

```text
tenancy
effective_from
amount_cents
due_day
```

For the currently-open term:

1. lock the relevant tenancy/current term;
2. validate that the change date lies inside the tenancy;
3. set the previous term's `effective_until` to one day before the new effective date;
4. create a new term beginning on the effective date;
5. commit atomically.

Do not modify the previous term's amount.

Example:

```text
Old:
$2,000
2026-01-01 .. nil

Change effective 2026-07-01:
$2,150

Result:

$2,000
2026-01-01 .. 2026-06-30

$2,150
2026-07-01 .. nil
```

Add tests proving the old term remains intact.

---

# 22. Rename controllers and routes

Replace core resource names:

```text
rental_properties -> properties
leases            -> tenancies
tenants           -> parties
```

Add nested units.

Target routing shape:

```ruby
resources :properties do
  resources :rentable_units
  resources :expenses, only: %i[new create]

  member do
    get :schedule_e
    get :schedule_e_pdf
  end
end

resources :parties

resources :tenancies do
  resources :tenant_payments, only: %i[new create]

  resources :tenancy_parties, only: %i[new create edit update destroy]
  resources :rent_terms, only: %i[new create]
end
```

Exact route structure may be adjusted for existing UI conventions, but old first-class resources:

```text
/rental_properties
/leases
/tenants
```

should be gone when this milestone is finished.

Current routes expose all three old resources directly.

---

# 23. Rename controllers

Replace:

```text
RentalPropertiesController -> PropertiesController
LeasesController           -> TenanciesController
TenantsController          -> PartiesController
```

Add:

```text
RentableUnitsController
TenancyPartiesController
RentTermsController
```

Retain authorization through `authenticated_user`.

Every lookup must be user-scoped.

Examples:

```text
authenticated_user.properties.find(...)
authenticated_user.parties.find(...)
```

For tenancy:

```text
authenticated_user.tenancies.find(...)
```

through correct user associations.

Never trust a `rentable_unit_id` or `party_id` merely because it exists.

---

# 24. Update User associations

Replace the existing old-domain associations on `User`.

Target core associations:

```ruby
has_many :properties
has_many :rentable_units, through: :properties
has_many :tenancies, through: :rentable_units

has_many :parties
```

Where convenient, tenancy-participant access may be through explicit joins.

Retarget surviving financial associations to the new roots.

The current `User` exposes rentals, leases, and tenants directly, so it must be part of the cutover rather than left as an adapter.

---

# 25. Property UI

Rename:

```text
app/views/rental_properties
    -> app/views/properties
```

Update all partial and variable names.

Property create/edit form fields:

```text
address
asset_type
square_footage
```

Remove old Schedule-E-oriented property types from the form.

On property show:

```text
Property details

Units
  Main Unit
  Unit A
  Unit B

[Add unit]
```

If there is only one rentable unit, the display may de-emphasize the abstraction, but it must still exist in persistence.

Retain surviving financial sections temporarily by adapting them to `Property`.

Do not redesign financial presentation in this milestone.

---

# 26. Rentable-unit UI

For properties with multiple units, support:

```text
list units
create unit
edit unit
deactivate unit
```

Do not hard-delete a unit that has a tenancy.

Prefer marking:

```text
active = false
```

for a used unit.

A unit with no history may be destroyed if existing application conventions make that useful.

Test authorization so one user cannot create/update units under another user's property.

---

# 27. Party UI

Rename:

```text
app/views/tenants
    -> app/views/parties
```

The user-facing heading can be something understandable such as:

```text
Tenants & Payers
```

while the domain/model remains `Party`.

Form fields:

```text
party_type
display_name
email_address
phone_number
mailing_address
aliases
```

Support both:

```text
Individual
Organization
```

Do not make organization-specific company fields in this milestone.

Retain nested alias editing.

---

# 28. Tenancy UI

Rename:

```text
app/views/leases
    -> app/views/tenancies
```

The tenancy form should select:

```text
Property / Rentable Unit
Agreement type
Commencement date
Termination date
Late-period days

Tenant parties
Optional guarantors/occupants

Initial monthly rent
Rent due day
```

Do not ask for:

```text
annual_rental_amount
security_deposit
```

Security deposits get their own model later.

A tenancy must be associated with a **unit**, not merely a property.

For single-unit properties, the UI may present only the property name and submit its sole unit automatically.

For multi-unit properties, require the user to choose the specific unit.

---

# 29. Tenancy show page

Display:

```text
Property
Unit
Agreement
Commencement
Termination
Participants
Current rent term
Rent history
```

Participants should show:

```text
party
role
effective_from
effective_until
```

Rent history should show all terms chronologically.

Add:

```text
[Change rent]
```

which invokes `RentTerms::Change`.

Do not provide a generic edit button that mutates an existing historical rent amount.

---

# 30. Participant management

Provide enough UI to:

```text
add a party to a tenancy
assign role
set effective_from
set effective_until
end participation
```

This is required to prove effective-dated tenancy membership works end to end.

Do not require deleting and recreating the entire tenancy when a roommate leaves or a guarantor is added.

---

# 31. Adapt the dashboard

Rename all property/lease/tenant references in dashboard code to the new core domain.

A property summary should traverse:

```text
Property
  -> RentableUnit
    -> Tenancy
```

rather than:

```text
RentalProperty
  -> Lease
```

The existing dashboard currently loads `authenticated_user.rental_properties` and nested leases/tenants, so both query and eager-loading shape must be updated.

Do not redesign financial calculations yet.

---

# 32. Adapt legacy financial models

Update model associations mechanically.

Examples:

```ruby
class Expense
  belongs_to :property
end
```

```ruby
class TenantPayment
  belongs_to :tenancy
end
```

```ruby
class TenantCharge
  belongs_to :tenancy
end
```

```ruby
class ScheduledRent
  belongs_to :tenancy
end
```

The current `Expense` directly belongs to `RentalProperty`; change only that core ownership in this milestone. Do not yet perform the full Expense redesign from the later PRD milestone.

---

# 33. Remove scheduled-rent generation from tenancy editing

Do not reproduce `annual_rental_amount` by adding a hidden compatibility field.

The existing `LeasesController` calls `Leases::SaveService` and can synchronize scheduled rents as part of saving a lease. That behavior is coupled to the model this milestone intentionally removes.

Therefore:

- remove automatic scheduled-rent synchronization from tenancy creation/update;
- remove any tenancy-form logic that derives scheduled rent from one annual amount;
- remove or disable the `generate_scheduled_rents` action if it cannot operate correctly from effective-dated terms without implementing Milestone 3 semantics.

Do **not** write throwaway rent-generation logic just to preserve that route.

`ScheduledRent` may remain readable temporarily for surviving old financial tests/data structures, but creation of future rent obligations belongs to the Charge milestone.

Document this temporary boundary clearly.

---

# 34. Adapt payment ingestion mechanically

Do not redesign ingestion yet.

Update it from:

```text
tenant -> Party
lease  -> Tenancy
```

This includes:

```text
model associations
matching services
confirmation services
forms
controller params
request specs
duplicate-payment queries
```

Continue creating the existing `TenantPayment` for now.

The purpose of this work is only to ensure no legacy `Tenant` or `Lease` domain object survives as an ingestion dependency.

Full `SourceDocument` / `ImportedTransaction` redesign remains deferred.

---

# 35. Rename query namespaces tied to core identities

Rename application-owned namespaces where the old identity is part of the domain vocabulary.

Examples:

```text
RentalProperties::FinancialItemsQuery
    -> Properties::FinancialItemsQuery

RentalProperties::ActiveYearsQuery
    -> Properties::ActiveYearsQuery

RentalProperties::ScheduleESummaryQuery
    -> Properties::ScheduleESummaryQuery

Leases::BalanceQuery
    -> Tenancies::BalanceQuery
```

Do not redesign their financial semantics yet.

Do not create compatibility namespace aliases.

---

# 36. Rename helper namespaces and view variables

Rename:

```text
rental_properties_helper -> properties_helper
leases_helper            -> tenancies_helper
tenants_helper           -> parties_helper
```

Update local variables consistently:

```text
@rental_property -> @property
@rental_properties -> @properties
@lease -> @tenancy
@leases -> @tenancies
@tenant -> @party
@tenants -> @parties
```

User-facing copy may still use normal landlord terminology such as "tenant"; internal model vocabulary should be consistent.

---

# 37. Update JSON builders

Rename and update the existing Jbuilder files under the three renamed resources.

Do not expose removed fields such as:

```text
annual_rental_amount
security_deposit
property_type
lease_type
```

Expose:

```text
asset_type
rentable_unit
agreement_type
participants
rent terms
```

where appropriate.

Avoid maintaining legacy JSON response shapes solely for compatibility because there are no external consumers specified by this milestone.

---

# 38. Update factories

Replace core factories:

```text
:rental_property -> :property
:lease           -> :tenancy
:tenant          -> :party
:lease_tenant    -> :tenancy_party
:tenant_alias    -> :party_alias
```

Add:

```text
:rentable_unit
:rent_term
```

Suggested dependency shape:

```ruby
factory :property do
  association :user
end

factory :rentable_unit do
  association :property
end

factory :tenancy do
  association :rentable_unit
end

factory :party do
  association :user
end

factory :tenancy_party do
  association :tenancy
  association :party
  role { :tenant }
end

factory :rent_term do
  association :tenancy
  amount_cents { 100_000 }
  frequency { :monthly }
  due_day { 1 }
end
```

The current factory graph mirrors the old property/lease/tenant structure and therefore must be rewritten, not supplemented.

Update surviving financial factories to associate with:

```text
property
tenancy
party
```

as appropriate.

---

# 39. Model test matrix

Add focused specs for each new model.

## Property

- [ ] Requires address.
- [ ] Requires valid asset type.
- [ ] Belongs to user.
- [ ] Can have multiple units.

## RentableUnit

- [ ] Requires property.
- [ ] Requires name.
- [ ] Validates positive square footage when present.
- [ ] Prevents duplicate nonblank unit identifier within one property.
- [ ] Allows same identifier on another property.

## Party

- [ ] Requires display name.
- [ ] Requires party type.
- [ ] Supports individual.
- [ ] Supports organization.
- [ ] Belongs to user.

## PartyAlias

- [ ] Requires alias.
- [ ] Strips surrounding whitespace.
- [ ] Prevents case-insensitive duplicate alias for the same party.
- [ ] Allows the same alias for a different party.

## Tenancy

- [ ] Requires unit.
- [ ] Requires commencement date.
- [ ] Validates termination date ordering.
- [ ] Fixed-term tenancy requires termination.
- [ ] Month-to-month tenancy may be open-ended.
- [ ] `active?` works before, during, and after the tenancy.
- [ ] Prevents overlapping tenancy on the same unit.
- [ ] Allows overlapping dates on different units.

## TenancyParty

- [ ] Requires supported role.
- [ ] Requires effective start.
- [ ] Validates effective-date ordering.
- [ ] Party and tenancy must belong to same user.
- [ ] Effective range stays inside tenancy range.
- [ ] Duplicate/overlapping same-role participation is rejected.
- [ ] Different valid roles may coexist.

## RentTerm

- [ ] Requires positive `amount_cents`.
- [ ] Supports monthly frequency.
- [ ] Rejects unsupported frequency.
- [ ] Validates due day 1 through 31.
- [ ] Effective range stays within tenancy.
- [ ] Prevents overlapping terms.
- [ ] Allows sequential terms.

---

# 40. Service test matrix

## Properties::Create

- [ ] Creates property and implicit unit atomically.
- [ ] Uses `Main Unit` when no units supplied.
- [ ] Rolls back property if unit creation fails.

## Tenancies::Create

- [ ] Creates tenancy.
- [ ] Creates at least one tenant participant.
- [ ] Creates initial rent term.
- [ ] Rejects no-tenant aggregate.
- [ ] Rejects another user's party.
- [ ] Rejects another user's unit.
- [ ] Rolls everything back on participant failure.
- [ ] Rolls everything back on rent-term failure.

## Tenancies::Update

- [ ] Updates allowed metadata.
- [ ] Does not update rent.
- [ ] Rejects invalid termination date.
- [ ] Rejects truncation that would invalidate participant history.
- [ ] Rejects truncation that would invalidate rent-term history.

## RentTerms::Change

- [ ] Closes old term one day before change.
- [ ] Creates new term.
- [ ] Preserves old amount.
- [ ] Rejects overlapping or invalid changes.
- [ ] Performs both writes atomically.

---

# 41. Request/system acceptance scenarios

Add end-to-end coverage for the actual milestone.

## Scenario A: single-family property

1. Sign in.
2. Create single-family property.
3. Open property.
4. Verify one implicit unit exists.
5. Verify normal UI does not unnecessarily force a unit-management decision.

## Scenario B: multifamily property

1. Create multifamily property.
2. Create Unit A.
3. Create Unit B.
4. Verify both appear independently.

## Scenario C: individual party

1. Create individual party.
2. Add alias.
3. Edit contact details.
4. Verify alias persists.

## Scenario D: organization party

1. Create organization.
2. Verify it can participate in the same domain associations as an individual.

## Scenario E: tenancy

1. Choose Unit A.
2. Choose one or more parties.
3. Create fixed-term tenancy.
4. Enter initial monthly rent.
5. Verify tenancy, participants, and rent term appear on show page.

## Scenario F: rent increase

1. Start at `$2,000/month`.
2. Change rent effective July 1 to `$2,150`.
3. Verify two non-overlapping terms.
4. Verify old term was not overwritten.

## Scenario G: participant change

1. Add second tenant effective later date.
2. End first tenant's participation.
3. Verify historical participation remains visible.

## Scenario H: multifamily isolation

1. Create tenancy for Unit A.
2. Create overlapping-date tenancy for Unit B.
3. Both succeed.
4. Attempt overlapping tenancy on Unit A.
5. It fails.

## Scenario I: authorization

Attempt using another user's:

```text
property
unit
party
tenancy
```

through submitted IDs.

All attempts must fail without exposing the other user's data.

---

# 42. Update RBS

Yanushi keeps hand-written application signatures in `sig/app/`, generated Rails signatures in `sig/rbs_rails/`, and explicitly lists typed source files in `Steepfile`. The repository documentation requires regenerating Rails signatures after schema changes.

Delete obsolete hand-written signatures for:

```text
RentalProperty
Lease
LeaseTenant
Tenant
TenantAlias
old controllers/services/namespaces
```

Add/update signatures for:

```text
Property
RentableUnit
Party
PartyAlias
Tenancy
TenancyParty
RentTerm

Properties::Create
Tenancies::Create
Tenancies::Update
RentTerms::Change

PropertiesController
RentableUnitsController
PartiesController
TenanciesController
TenancyPartiesController
RentTermsController
```

Update `Steepfile` so every new application-owned source file that should be checked is included.

Then regenerate Rails-aware signatures:

```bash
bin/rails rbs_rails:all
bundle exec rbs validate
bundle exec steep check
```

Do not hand-edit generated `sig/rbs_rails/` files.

---

# 43. Remove obsolete core files

Once all references are migrated, delete:

```text
app/models/rental_property.rb
app/models/lease.rb
app/models/lease_tenant.rb
app/models/tenant.rb
app/models/tenant_alias.rb

app/controllers/rental_properties_controller.rb
app/controllers/leases_controller.rb
app/controllers/tenants_controller.rb

app/views/rental_properties/
app/views/leases/
app/views/tenants/
```

and old corresponding helpers, signatures, request specs, model specs, and namespace files after their replacements exist.

Do not retain forwarding classes, deprecated constants, or old routes.

---

# 44. Search for stale vocabulary

Run:

```bash
rg -n \
  '\bRentalProperty\b|\brental_property\b|\bRentalProperties::|\bLease\b|\blease_id\b|\bLeases::|\bLeaseTenant\b|\bannual_rental_amount\b|\bproperty_type\b|\blease_type\b' \
  app config db spec sig
```

Expected result:

```text
no application-code hits
```

Then separately inspect:

```bash
rg -n '\bTenant\b|\btenant_id\b' app config db spec sig
```

Some results are intentionally allowed because the later milestones have not yet renamed:

```text
TenantPayment
TenantCharge
tenant_payments
tenant_charges
```

Standalone references to the removed core `Tenant` model or `tenant_id` pointing at a person are not allowed.

Also check:

```bash
rg -n '\bsecurity_deposit\b' app config db spec sig
```

There should be no security-deposit field left on `Tenancy`.

Fixtures/document-ingestion text mentioning a security deposit as document content is allowed.

---

# 45. Update documentation

Update README language enough that it no longer tells developers the application is structurally:

```text
Property -> Lease -> Tenant
```

Document the new core:

```text
Property -> RentableUnit -> Tenancy
Tenancy -> TenancyParty -> Party
Tenancy -> RentTerm
```

Clearly mark that:

```text
ScheduledRent
TenantPayment
TenantCharge
```

are still legacy financial models awaiting later architecture milestones.

Do not rewrite the README to claim the double-entry architecture is already implemented.

Add a short architecture document if useful:

```text
documentation/rental_domain.md
```

covering:

- Property vs RentableUnit;
- Party vs tenancy role;
- Tenancy lifetime;
- effective-dated participation;
- effective-dated rent;
- same-unit occupancy overlap rule;
- why rent is not stored on Tenancy.

---

# 46. Final database verification

From a clean database:

```bash
bin/rails db:drop db:create db:migrate
```

Verify:

```bash
bin/rails runner 'puts Property.count'
```

boots successfully.

Verify Rails loads all new constants:

```bash
bin/rails runner '
  [
    Property,
    RentableUnit,
    Party,
    PartyAlias,
    Tenancy,
    TenancyParty,
    RentTerm
  ].each { |klass| puts klass.name }
'
```

Verify removed constants do not exist in application code.

---

# 47. Final quality gate

Run all checks required by the repository.

At minimum:

```bash
bin/rubocop
bundle exec rbs validate
bundle exec steep check
bundle exec rspec
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

Current CI separately runs RuboCop, Steep, the full RSpec suite, security scans, and enforces at least 95% line coverage.

Do not consider the milestone complete merely because focused model specs pass.

---

# 48. Manual smoke test

Run:

```bash
bin/dev
```

Using a clean development database, manually verify:

1. Sign in.
2. Create a single-family property.
3. Confirm implicit unit.
4. Create a multifamily property.
5. Add two units.
6. Create an individual party.
7. Create an organization party.
8. Add aliases.
9. Create a tenancy for Unit A with one tenant.
10. Verify its initial rent term.
11. Add another participant.
12. Change the rent effective on a later date.
13. Verify rent history.
14. Create a simultaneous tenancy in Unit B.
15. Verify an overlapping tenancy in Unit A is rejected.
16. Open dashboard.
17. Open property page.
18. Exercise any surviving expense/payment/ingestion pages.
19. Confirm no page raises because it still expects `RentalProperty`, `Lease`, or `Tenant`.

Fix failures instead of documenting them as expected breakage, except for the intentionally removed scheduled-rent generation flow described above.

---

# 49. Suggested green commit boundaries

Do not force commits if the implementation naturally organizes differently, but these are useful review boundaries.

## Commit 1: Core domain schema and models

Include:

```text
schema migration
Property
RentableUnit
Party
PartyAlias
Tenancy
TenancyParty
RentTerm
model specs
factory foundations
```

Do not commit while the application test suite is globally broken unless the branch is explicitly being developed as an unreviewable intermediate state.

## Commit 2: Property, unit, and party application flows

Include:

```text
Properties::Create
property/unit controllers
party controller
routes
views
request/system specs
```

## Commit 3: Tenancy and rent-term application flows

Include:

```text
Tenancies::Create
Tenancies::Update
RentTerms::Change
tenancy participants
tenancy/rent-term controllers
views
request/system specs
```

## Commit 4: Legacy financial edge adaptation

Include:

```text
Expense -> Property
TenantPayment -> Tenancy
TenantCharge -> Tenancy
ScheduledRent -> Tenancy
PaymentIngestion -> Party/Tenancy
dashboard/query namespace changes
```

## Commit 5: Typing, docs, and old-domain deletion

Include:

```text
RBS
Steepfile
generated Rails signatures
README/docs
stale reference cleanup
deleted old files
```

Every final commit should leave the branch green.

---

# 50. Explicit non-goals for this milestone

Do not implement:

- [ ] `Account`.
- [ ] `JournalEntry`.
- [ ] `Posting`.
- [ ] `Charge`.
- [ ] `Receipt`.
- [ ] `SecurityDeposit`.
- [ ] `SecurityDepositTransaction`.
- [ ] `PropertyTaxProfile`.
- [ ] Schedule E accounting-basis redesign.
- [ ] Receipt allocations.
- [ ] SourceDocument/ImportedTransaction redesign.
- [ ] Expense reimbursement redesign.
- [ ] New scheduled-rent semantics.
- [ ] Double-entry posting.
- [ ] Journal reversals.
- [ ] Financial-balance migration to postings.

If implementation work starts requiring any of these to make Milestone 1 work, first reconsider the boundary rather than silently pulling later milestones forward.

---

# 51. Milestone acceptance checklist

The agent is done only when all of these are true.

## Domain

- [ ] `Property` replaces `RentalProperty`.
- [ ] `RentableUnit` exists between property and tenancy.
- [ ] Every newly-created property receives at least one unit.
- [ ] `Party` replaces the person-specific `Tenant` model.
- [ ] `Party` supports individuals and organizations.
- [ ] `PartyAlias` replaces `TenantAlias`.
- [ ] `Tenancy` replaces `Lease`.
- [ ] `TenancyParty` replaces `LeaseTenant`.
- [ ] Tenancy participants have roles.
- [ ] Tenancy participants have effective dates.
- [ ] `RentTerm` exists.
- [ ] Rent is no longer stored directly on tenancy.
- [ ] Rent can change by creating effective-dated history.
- [ ] Security-deposit amount is no longer stored on tenancy.
- [ ] Tax-specific values are no longer physical property types.

## Invariants

- [ ] Same unit cannot have overlapping tenancies.
- [ ] Different units may have simultaneous tenancies.
- [ ] Tenancy requires at least one tenant-role participant.
- [ ] Cross-user participant assignment is impossible.
- [ ] Cross-user unit assignment is impossible.
- [ ] Same-role participant date ranges do not overlap.
- [ ] Rent-term ranges do not overlap.
- [ ] Rent terms remain inside tenancy bounds.
- [ ] Rent amounts use integer cents.

## Application

- [ ] Property CRUD uses `Property`.
- [ ] Unit CRUD works.
- [ ] Party CRUD works.
- [ ] Tenancy CRUD works.
- [ ] Participant management works.
- [ ] Initial rent creation works.
- [ ] Rent change works.
- [ ] Dashboard traverses new relationships.
- [ ] Surviving financial code points to new core identities.
- [ ] Payment ingestion no longer references a `Tenant` or `Lease` record.
- [ ] Old core routes are removed.
- [ ] Old core controllers/views/models are removed.
- [ ] No compatibility aliases remain.

## Tests and typing

- [ ] Model tests cover domain invariants.
- [ ] Service tests cover aggregate atomicity.
- [ ] Request/system tests cover the milestone scenarios.
- [ ] Rails RBS has been regenerated.
- [ ] Hand-written RBS is updated.
- [ ] `Steepfile` includes the new typed code.
- [ ] `bundle exec rbs validate` passes.
- [ ] `bundle exec steep check` passes.
- [ ] `bin/rubocop` passes.
- [ ] `bundle exec rspec` passes.
- [ ] Coverage remains at or above the repository threshold.
- [ ] Security scans pass.

---

# 52. End state

After Milestone 1, a representative record graph should look like:

```text
User: Kyle

Property:
  100 Main Street
  asset_type: multifamily

  RentableUnit:
    Unit A

    Tenancy:
      2026-01-01 .. nil
      agreement_type: month_to_month

      TenancyParty:
        Alice Smith
        role: tenant
        2026-01-01 .. nil

      TenancyParty:
        Bob Smith
        role: tenant
        2026-04-01 .. nil

      RentTerm:
        $2,000/month
        due day: 1
        2026-01-01 .. 2026-06-30

      RentTerm:
        $2,150/month
        due day: 1
        2026-07-01 .. nil

  RentableUnit:
    Unit B

    Tenancy:
      2026-03-01 .. nil
      ...
```

The application should no longer need to ask:

```text
Which lease owns this rent amount?
```

because rent belongs to effective-dated terms.

It should no longer need to ask:

```text
Which property is this lease for?
```

without being able to identify the rented unit.

And it should no longer equate:

```text
tenant = person
```

because a tenancy participant and a reusable party are separate concepts.

That is the foundation Milestone 2 can safely place the accounting ledger underneath.
