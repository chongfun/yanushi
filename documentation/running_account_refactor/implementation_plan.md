# Implementation Plan: Running Account Refactor [STATUS: FLAWLESSLY COMPLETED]

## Overview [COMPLETED]

Refactor tenant payments from a direct-linkage model (`RentPayment` → `ScheduledRent`, `UtilityPayment` → `Expense`) to a **ledger-based running account** per lease. Payments become unlinked credits; scheduled rents and reimbursable expenses become debits. The balance determines whether obligations are met.

### Goals [COMPLETED]

- A single tenant payment can cover rent, utilities, or both
- Overpayments carry forward as credit
- Manually-entered payments use the same `TenantPayment` model

### Decisions [COMPLETED]

| Question | Answer |
|----------|--------|
| When is a `TenantCharge` created? | Only when the landlord **explicitly marks** an expense as tenant-reimbursable |
| Dashboard balance display? | Simple number per lease (positive = credit, negative = owed) |
| Manual payments? | Also use `TenantPayment` — universal model |

---

## Phase 1 — Schema Changes [COMPLETED]

### 1.1 New Table: `tenant_payments` (credits)

Replaces both `rent_payments` and `utility_payments`. Represents money received from a tenant, regardless of purpose.

```ruby
# db/migrate/XXXXXXXX_create_tenant_payments.rb
create_table :tenant_payments do |t|
  t.references :lease, null: false, foreign_key: true
  t.decimal    :amount, null: false
  t.date       :payment_date, null: false
  t.string     :payment_method, null: false
  t.string     :transaction_number
  t.timestamps
end
```

### 1.2 New Table: `tenant_charges` (debits for reimbursable expenses)

Created when the landlord explicitly marks an expense as tenant-reimbursable.

```ruby
# db/migrate/XXXXXXXX_create_tenant_charges.rb
create_table :tenant_charges do |t|
  t.references :lease, null: false, foreign_key: true
  t.references :expense, null: false, foreign_key: true
  t.decimal    :amount, null: false
  t.date       :charge_date, null: false
  t.string     :description
  t.timestamps
end
```

### 1.4 Modify `scheduled_rents`

Remove the `paid` boolean — paid status is now derived from the running balance.

```ruby
# db/migrate/XXXXXXXX_remove_paid_from_scheduled_rents.rb
remove_column :scheduled_rents, :paid, :boolean
```

### 1.5 Data Migration

Before dropping old tables, migrate existing data:

```ruby
# db/migrate/XXXXXXXX_migrate_payments_to_ledger.rb
#
# For each RentPayment, create a TenantPayment on the same lease.
# For each UtilityPayment, create a TenantPayment on the same lease.
# If a UtilityPayment has an expense_id, also create a TenantCharge.
```

### 1.6 Drop Old Tables

```ruby
# db/migrate/XXXXXXXX_drop_old_payment_tables.rb
drop_table :rent_payments
drop_table :utility_payments
```

### 1.7 Migration Execution Order

1. `CreateTenantPayments` — new table
2. `CreateTenantCharges` — new table
3. `MigratePaymentsToLedger` — data migration (reversible)
4. `RemovePaidFromScheduledRents` — drop derived column
5. `DropOldPaymentTables` — drop `rent_payments` and `utility_payments`

---

## Phase 2 — Model Changes [COMPLETED]

### 2.1 New Model: `TenantPayment`

```ruby
# app/models/tenant_payment.rb
class TenantPayment < ApplicationRecord
  belongs_to :lease

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_date, presence: true
  validates :payment_method, presence: true
end
```

### 2.2 New Model: `TenantCharge`

```ruby
# app/models/tenant_charge.rb
class TenantCharge < ApplicationRecord
  belongs_to :lease
  belongs_to :expense

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :charge_date, presence: true
end
```

### 2.3 Modified: `Lease`

Add `tenant_payments` and `tenant_charges` associations. Remove `utility_payments`. Add balance calculation methods. Support in-place renewals and conversions via `after_update` and month-to-month range calculation.

```ruby
class Lease < ApplicationRecord
  belongs_to :rental_property
  has_many :lease_tenants, dependent: :destroy
  has_many :tenants, through: :lease_tenants
  has_many :scheduled_rents, dependent: :destroy
  has_many :tenant_payments, dependent: :destroy
  has_many :tenant_charges, dependent: :destroy

  enum :lease_type, { month_to_month: 0, term: 1 }

  after_create :generate_scheduled_rents
  after_update :generate_scheduled_rents

  # Total credits (payments received) up to a given date
  def total_credits(as_of: Date.current)
    tenant_payments.where("payment_date <= ?", as_of).sum(:amount)
  end

  # Total debits (rents + charges) up to a given date
  def total_debits(as_of: Date.current)
    rent_debits = scheduled_rents.where("due_date <= ?", as_of).sum(:amount)
    charge_debits = tenant_charges.where("charge_date <= ?", as_of).sum(:amount)
    rent_debits + charge_debits
  end

  # Positive = tenant has credit, negative = tenant owes money
  def balance_as_of(date = Date.current)
    total_credits(as_of: date) - total_debits(as_of: date)
  end

  def current_balance
    balance_as_of(Date.current)
  end

  private

  def generate_scheduled_rents
    first_due_date = if commencement_date.day == 1
      commencement_date
    else
      (commencement_date + 1.month).beginning_of_month
    end

    end_date = if term?
      termination_date
    else
      if previously_new_record?
        first_due_date + 11.months
      else
        [first_due_date + 11.months, Date.current + 12.months].max
      end
    end

    return unless end_date

    # Use first_due_date's year to ensure we generate from the starting year
    (first_due_date.year..end_date.year).each do |year|
      ScheduledRentsGenerator.new(self, year, end_date: end_date).call
    end
  end
end
```

### 2.4 Modified: `ScheduledRent`

Remove `paid` boolean, `rent_payments` association, and `balance_due`/`partial_payment?` methods. Replace with `covered?` derived from balance.

```ruby
class ScheduledRent < ApplicationRecord
  belongs_to :lease

  def covered?
    lease.balance_as_of(due_date) >= 0
  end

  def late?
    !covered? && Date.current > (due_date + lease.late_period_days.days)
  end

  def display_name
    "#{lease.rental_property.address} - #{due_date}"
  end
end
```

### 2.6 Modified: `RentalProperty`

Update associations and `financial_items` method.

```ruby
class RentalProperty < ApplicationRecord
  belongs_to :user
  has_many :leases, dependent: :destroy
  has_many :scheduled_rents, through: :leases
  has_many :expenses, dependent: :destroy
  has_many :tenant_payments, through: :leases
  has_many :tenant_charges, through: :leases

  # ... property_type enum unchanged ...

  def financial_items(year)
    start_date = Date.new(year.to_i, 1, 1)
    end_date = start_date.end_of_year
    items = []

    scheduled_rents.where(due_date: start_date..end_date).each do |sr|
      items << { date: sr.due_date, type: "Scheduled Rent", amount: sr.amount, object: sr }
    end

    tenant_payments.where(payment_date: start_date..end_date).each do |tp|
      items << { date: tp.payment_date, type: "Tenant Payment", amount: tp.amount, object: tp }
    end

    tenant_charges.where(charge_date: start_date..end_date).each do |tc|
      items << { date: tc.charge_date, type: "Tenant Charge", amount: tc.amount, object: tc }
    end

    expenses.where(expense_date: start_date..end_date).each do |exp|
      items << { date: exp.expense_date, type: "Expense", amount: exp.amount, object: exp }
    end

    items.sort_by { |item| item[:date] }
  end
end
```

### 2.7 Modified: `Expense`

Add optional association to `TenantCharge` and a helper method.

```ruby
class Expense < ApplicationRecord
  belongs_to :rental_property
  has_one :tenant_charge, dependent: :destroy

  # ... existing validations and enum unchanged ...

  def reimbursed?
    tenant_charge.present?
  end
end
```

### 2.8 Modified: `Tenant`

Replace `utility_payments` association with `tenant_payments`.

```ruby
class Tenant < ApplicationRecord
  belongs_to :user
  has_many :lease_tenants, dependent: :destroy
  has_many :leases, through: :lease_tenants
  has_many :tenant_payments, through: :leases

  # ... rest unchanged ...
end
```

### 2.9 Models Deleted

| Model | File | Reason |
|-------|------|--------|
| `RentPayment` | `app/models/rent_payment.rb` | Replaced by `TenantPayment` |
| `UtilityPayment` | `app/models/utility_payment.rb` | Replaced by `TenantPayment` + `TenantCharge` |

---

## Phase 3 — Service Changes [COMPLETED]

### 3.1 `ScheduledRentsGenerator`

Generates rents for each month of the calendar year, aligning to the 1st of the month, ensuring that the first due date is strictly on or after the lease commencement date, and truncating the monthly amount to exactly 2 decimal places (ignoring any remainder cents).

```ruby
class ScheduledRentsGenerator
  def initialize(lease, year, end_date: nil)
    @lease = lease
    @year = year.to_i
    @end_date = end_date
  end

  def call
    amount = (@lease.annual_rental_amount / 12.0).truncate(2)
    first_due_date = first_due_date_for(@lease.commencement_date)

    1.upto(12) do |month|
      date = Date.new(@year, month, 1)

      # Skip if before the first due date
      next if date < first_due_date

      # Skip if after lease end (for term leases)
      if @lease.term? && @lease.termination_date
        next if date > @lease.termination_date.beginning_of_month
      end

      if @end_date
        next if date > @end_date.beginning_of_month
      end

      # Check for existing scheduled rent in this month
      unless @lease.scheduled_rents.where(due_date: date.beginning_of_month..date.end_of_month).exists?
        @lease.scheduled_rents.create!(
          amount: amount,
          due_date: date
        )
      end
    end
  end

  private

  def first_due_date_for(date)
    if date.day == 1
      date
    else
      (date + 1.month).beginning_of_month
    end
  end
end
```

### 3.2 `ScheduleEGenerator`

The `rents_received` method changes to query `tenant_payments` (all tenant income is rental income for tax purposes). The separate `utility_payment_total` method is eliminated.

```ruby
def rents_received
  @property.tenant_payments
           .where(payment_date: date_range)
           .sum(:amount)
end
```

---

## Phase 4 — Controller & Route Changes [COMPLETED]

### 4.1 New Controller: `TenantPaymentsController`

Replaces `RentPaymentsController`. Supports the same CRUD operations + PDF receipt + Turbo modal creation from the financials view.

**Key differences from `RentPaymentsController`:**
- `new` action defaults amount to `lease.current_balance.abs` (amount owed) instead of `scheduled_rent.balance_due`
- `create` no longer requires a `scheduled_rent_id`
- PDF receipt shows lease/property info instead of scheduled rent info
- No `set_scheduled_rent` callback — payments are against the lease, not a specific rent

**File:** `app/controllers/tenant_payments_controller.rb`

### 4.2 New Controller: `TenantChargesController`

Minimal controller for creating/managing tenant charges. Charges are typically created from the expense show/edit page when the landlord marks an expense as reimbursable.

**File:** `app/controllers/tenant_charges_controller.rb`

### 4.3 Modified: `ExpensesController`

Update `expense_params` to accept a `tenant_reimbursable` flag. When the flag is set on create/update, create or destroy the associated `TenantCharge`.

### 4.4 Modified: `RentalPropertiesController`

Update `schedule_e` action to query `tenant_payments` instead of `rent_payments` + `utility_payments`.

```ruby
def schedule_e
  @year = params[:year].present? ? params[:year].to_i : Date.current.year
  start_date = Date.new(@year, 1, 1)
  end_date   = start_date.end_of_year

  @total_income = @rental_property.tenant_payments
                    .where(payment_date: start_date..end_date)
                    .sum(:amount)

  @expenses_by_category = @rental_property.expenses
                            .where(expense_date: start_date..end_date)
                            .group(:category)
                            .sum(:amount)

  @total_expenses = @expenses_by_category.values.sum
  @net_income = @total_income - @total_expenses
end
```

### 4.5 Controllers Deleted

| Controller | File | Reason |
|------------|------|--------|
| `RentPaymentsController` | `app/controllers/rent_payments_controller.rb` | Replaced by `TenantPaymentsController` |
| `UtilityPaymentsController` | `app/controllers/utility_payments_controller.rb` | Replaced by `TenantChargesController` + expense flag |

### 4.6 Route Changes

```ruby
# config/routes.rb — changes:

# REMOVE:
# resources :utility_payments
# resources :rent_payments
# resources :scheduled_rents do
#   resources :rent_payments, only: [:new, :create]
# end

# ADD:
resources :tenant_payments
resources :tenant_charges, only: [:show, :destroy]
resources :leases do
  resources :tenant_payments, only: [:new, :create]
  post :generate_scheduled_rents, on: :member
end
```

---

## Phase 5 — View Changes [COMPLETED]

### 5.1 New Views: `tenant_payments/`

Replace the entire `rent_payments/` view directory. Same structure:

| File | Purpose |
|------|---------|
| `index.html.erb` | List all tenant payments |
| `show.html.erb` | Payment detail + PDF receipt |
| `new.html.erb` | Standalone new payment form |
| `edit.html.erb` | Edit payment |
| `_form.html.erb` | Form partial (lease selector instead of scheduled_rent selector) |
| `_modal_form.html.erb` | Turbo modal form for financials view |
| `_tenant_payment.json.jbuilder` | JSON partial |

### 5.2 Modified: `rental_properties/_financials.html.erb`

- Replace `'Rent Payment'` badge with `'Tenant Payment'`
- Replace `'Utility Payment'` badge with `'Tenant Charge'`
- Replace `"＋ Record Payment"` link (which pointed to `new_scheduled_rent_rent_payment_path`) with a link to `new_lease_tenant_payment_path(lease)`
- Replace `item[:object].balance_due` for Scheduled Rent rows with display based on `item[:object].covered?`
- Remove `item[:object].partial_payment?` check
- Add `'Tenant Charge'` row rendering with expense description

### 5.3 Modified: `rental_properties/show.html.erb`

Add a **Lease Balance** stat card showing `lease.current_balance` for each active lease.

### 5.4 Modified: `dashboards/index.html.erb`

Replace the income calculation:

```erb
<%# BEFORE: %>
<% income = property.leases.joins(scheduled_rents: :rent_payments).sum('rent_payments.amount') + property.utility_payments.sum(:amount) %>

<%# AFTER: %>
<% income = property.tenant_payments.sum(:amount) %>
```

Add per-lease balance display as a simple number.

### 5.5 Modified: `shared/_navbar.html.erb`

- Replace "Rent Payments" link → "Payments" pointing to `tenant_payments_path`
- Remove "Utility Payments" link entirely
- Update mobile dropdown menu similarly

### 5.7 Modified: `expenses/_form.html.erb` and `expenses/_modal_form.html.erb`

Add a **"Tenant Reimbursable"** checkbox. When checked, the form includes fields for selecting which lease to charge and the charge amount (defaulting to the expense amount).

### 5.8 Modified: `expenses/show.html.erb`

Show reimbursement status. If the expense has an associated `TenantCharge`, display it with a link.

### 5.9 Views Deleted

| Directory | Reason |
|-----------|--------|
| `app/views/rent_payments/` | Replaced by `tenant_payments/` |
| `app/views/utility_payments/` | Functionality moved to expense form + tenant_charges |

---

## Phase 6 — Testing Strategy [COMPLETED]

Use TDD (red-green-refactor). Write tests first, verify they fail, then implement.

### 6.1 Model Tests

| Test File | Coverage |
|-----------|----------|
| `test/models/tenant_payment_test.rb` | Validations (amount > 0, payment_date, payment_method presence), lease association |
| `test/models/tenant_charge_test.rb` | Validations (amount > 0, charge_date presence), lease + expense associations |
| `test/models/lease_test.rb` | `total_credits`, `total_debits`, `balance_as_of`, `current_balance` with various scenarios |
| `test/models/scheduled_rent_test.rb` | `covered?` returns true when balance >= 0, false when negative; `late?` logic |
| `test/models/expense_test.rb` | `reimbursed?` returns true when tenant_charge exists |

### 6.2 Service Tests

| Test File | Coverage |
|-----------|----------|
| `test/services/schedule_e_generator_test.rb` | **Update**: replace `RentPayment.create!` + `UtilityPayment.create!` with `TenantPayment.create!`, update expected `rents_received` calculation |

### 6.3 Controller Tests

| Test File | Coverage |
|-----------|----------|
| `test/controllers/tenant_payments_controller_test.rb` | **New**: CRUD operations, PDF receipt, Turbo modal flow |
| `test/controllers/tenant_charges_controller_test.rb` | **New**: show, destroy |
| `test/controllers/expenses_controller_test.rb` | **Update**: test tenant_reimbursable flag creates/destroys TenantCharge |
| `test/controllers/rental_properties_controller_test.rb` | **Update**: schedule_e income calculation uses tenant_payments |

### 6.4 Balance Scenario Tests

Key scenarios to test in `lease_test.rb`:

```
Scenario 1: Simple monthly rent
  Jan 1: Rent $1,200 due       → balance: -$1,200
  Jan 5: Payment $1,200        → balance: $0
  Result: January rent covered ✓

Scenario 2: Payment covers rent + utility
  Jan 1: Rent $1,200 due       → balance: -$1,200
  Jan 3: Payment $1,500        → balance: +$300
  Jan 15: Charge $300 (utility) → balance: $0
  Result: January rent covered ✓, utility charge covered ✓

Scenario 3: Overpayment carries forward
  Jan 1: Rent $1,200 due       → balance: -$1,200
  Jan 3: Payment $2,400        → balance: +$1,200
  Feb 1: Rent $1,200 due       → balance: $0
  Result: Both months covered ✓

Scenario 4: Partial payment
  Jan 1: Rent $1,200 due       → balance: -$1,200
  Jan 5: Payment $600          → balance: -$600
  Result: January rent NOT covered, balance = -$600

Scenario 5: Late payment
  Jan 1: Rent $1,200 due       → balance: -$1,200
  (late_period_days = 3, current date = Jan 10)
  Result: late? returns true
```

### 6.5 Tests Deleted

| Test File | Reason |
|-----------|--------|
| `test/models/rent_payment_test.rb` | Model deleted |
| `test/models/utility_payment_test.rb` | Model deleted |
| `test/controllers/rent_payments_controller_test.rb` | Controller deleted |
| `test/controllers/utility_payments_controller_test.rb` | Controller deleted |

### 6.6 Fixtures Updated

| Fixture | Change |
|---------|--------|
| `rent_payments.yml` | **Delete** |
| `utility_payments.yml` | **Delete** |
| `tenant_payments.yml` | **Create** — payment fixtures linked to lease |
| `tenant_charges.yml` | **Create** — charge fixtures linked to lease + expense |
| `scheduled_rents.yml` | Remove `paid` field |

---

## Phase 7 — Seed Data [COMPLETED]

Update `db/seeds.rb` to use the new models:

```ruby
# Replace:
#   RentPayment.create!(scheduled_rent: sr, ...)
#   UtilityPayment.create!(lease: lease, ...)
# With:
#   TenantPayment.create!(lease: lease, amount: 1200, payment_date: ..., payment_method: "ach")
#   TenantCharge.create!(lease: lease, expense: expense, amount: expense.amount, charge_date: ...)
```

---

## File Change Summary

### New Files

| Action | File |
|--------|------|
| **Create** | `db/migrate/XXXXXXXX_create_tenant_payments.rb` |
| **Create** | `db/migrate/XXXXXXXX_create_tenant_charges.rb` |
| **Create** | `db/migrate/XXXXXXXX_migrate_payments_to_ledger.rb` |
| **Create** | `db/migrate/XXXXXXXX_remove_paid_from_scheduled_rents.rb` |
| **Create** | `db/migrate/XXXXXXXX_drop_old_payment_tables.rb` |
| **Create** | `app/models/tenant_payment.rb` |
| **Create** | `app/models/tenant_charge.rb` |
| **Create** | `app/controllers/tenant_payments_controller.rb` |
| **Create** | `app/controllers/tenant_charges_controller.rb` |
| **Create** | `app/views/tenant_payments/` (index, show, new, edit, _form, _modal_form, jbuilders) |
| **Create** | `test/models/tenant_payment_test.rb` |
| **Create** | `test/models/tenant_charge_test.rb` |
| **Create** | `test/controllers/tenant_payments_controller_test.rb` |
| **Create** | `test/controllers/tenant_charges_controller_test.rb` |
| **Create** | `test/fixtures/tenant_payments.yml` |
| **Create** | `test/fixtures/tenant_charges.yml` |

### Modified Files

| Action | File |
|--------|------|
| **Modify** | `app/models/lease.rb` — add associations + balance methods |
| **Modify** | `app/models/scheduled_rent.rb` — remove `paid`/`balance_due`/`partial_payment?`, add `covered?` |
| **Modify** | `app/models/rental_property.rb` — update associations + `financial_items` |
| **Modify** | `app/models/expense.rb` — add `has_one :tenant_charge`, add `reimbursed?` |
| **Modify** | `app/models/tenant.rb` — replace `utility_payments` with `tenant_payments` |
| **Modify** | `app/services/schedule_e_generator.rb` — query `tenant_payments` for income |
| **Modify** | `app/controllers/expenses_controller.rb` — add reimbursable flag handling |
| **Modify** | `app/controllers/rental_properties_controller.rb` — update `schedule_e` action |
| **Modify** | `app/views/rental_properties/_financials.html.erb` — new item types |
| **Modify** | `app/views/rental_properties/show.html.erb` — add lease balance stat |
| **Modify** | `app/views/dashboards/index.html.erb` — use `tenant_payments` for income |
| **Modify** | `app/views/shared/_navbar.html.erb` — "Payments" link, remove "Utility Payments" |
| **Modify** | `app/views/expenses/_form.html.erb` — add reimbursable checkbox |
| **Modify** | `app/views/expenses/_modal_form.html.erb` — add reimbursable checkbox |
| **Modify** | `app/views/expenses/show.html.erb` — show reimbursement status |
| **Modify** | `config/routes.rb` — replace rent/utility payment routes |
| **Modify** | `db/seeds.rb` — use new models |
| **Modify** | `test/services/schedule_e_generator_test.rb` — use `TenantPayment` |
| **Modify** | `test/controllers/expenses_controller_test.rb` — test reimbursable flow |
| **Modify** | `test/controllers/rental_properties_controller_test.rb` — update income queries |
| **Modify** | `test/models/scheduled_rent_test.rb` — test `covered?` and `late?` |
| **Modify** | `test/models/lease_test.rb` — test balance methods |
| **Modify** | `test/models/expense_test.rb` — test `reimbursed?` |

### Deleted Files

| Action | File |
|--------|------|
| **Delete** | `app/models/rent_payment.rb` |
| **Delete** | `app/models/utility_payment.rb` |
| **Delete** | `app/controllers/rent_payments_controller.rb` |
| **Delete** | `app/controllers/utility_payments_controller.rb` |
| **Delete** | `app/helpers/rent_payments_helper.rb` |
| **Delete** | `app/helpers/utility_payments_helper.rb` |
| **Delete** | `app/views/rent_payments/` (entire directory) |
| **Delete** | `app/views/utility_payments/` (entire directory) |
| **Delete** | `test/models/rent_payment_test.rb` |
| **Delete** | `test/models/utility_payment_test.rb` |
| **Delete** | `test/controllers/rent_payments_controller_test.rb` |
| **Delete** | `test/controllers/utility_payments_controller_test.rb` |
| **Delete** | `test/fixtures/rent_payments.yml` |
| **Delete** | `test/fixtures/utility_payments.yml` |
