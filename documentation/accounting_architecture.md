# Double-Entry Accounting Engine Architecture (Milestone 2)

## Overview

Milestone 2 introduces the core double-entry accounting foundation into Yanushi. The accounting subsystem is ledger-based, immutable, strictly balanced, and idempotent.

## Core Models

### 1. Account (`accounts`)
- **Ownership**: Belongs to `User`.
- **Account Types**: `asset`, `liability`, `equity`, `income`, `expense`.
- **Fields**: `user_id`, `key`, `name`, `account_type`, `active`, `created_at`, `updated_at`.
- **Immutability**: `user_id`, `key`, and `account_type` are immutable once created.
- **System Accounts**: Provisioned automatically on `User` creation via `Accounting::ChartOfAccounts.ensure_for(user)`.

### 2. JournalEntry (`journal_entries`)
- **Ownership**: Belongs to `User`.
- **Source Event Uniqueness**: Unique index on `(user_id, source_type, source_id, event_type)`.
- **Reversal Tracking**: Optional `reversal_of_id` uniquely indexed to enforce at most one reversal per entry.
- **Fields**: `user_id`, `source_type`, `source_id`, `event_type`, `occurred_on`, `posted_at`, `description`, `reversal_of_id`, `created_at`.
- **Immutability**: No `updated_at` column. `before_update` and `before_destroy` abort modifications on persisted records.

### 3. Posting (`postings`)
- **Signed Amounts**: `amount_cents` (bigint) where positive is debit, negative is credit. Database check constraint enforces `amount_cents <> 0`.
- **Dimensions**:
  - `property_id` (`Property`)
  - `rentable_unit_id` (`RentableUnit`)
  - `tenancy_id` (`Tenancy`)
  - `party_id` (`Party`)
  - `memo` (`text`)
- **Dimension Hierarchy**: Automatically derived and validated (`Tenancy` -> `RentableUnit` -> `Property`). Contradictory dimensions or cross-user dimensions are rejected.
- **Immutability**: No `updated_at` column. `before_update` and `before_destroy` abort modifications on persisted records.

## Key Services

### `Accounting::ChartOfAccounts`
- `Accounting::ChartOfAccounts.ensure_for(user)` ensures the 17 standard system accounts exist for a user.
- Idempotent and safe to run repeatedly.

### `Accounting::PostingSpec`
- Pure value object representing an unpersisted posting specification (`account_key`, `amount_cents`, `property`, `rentable_unit`, `tenancy`, `party`, `memo`).

### `Accounting::PostingBuilder`
- Validates at least 2 lines, non-zero amounts, and balanced net sum ($\sum \text{amount\_cents} = 0$).
- Resolves account keys against active user accounts.
- Derives and validates dimension hierarchies and ownership.

### `Accounting::PostEntryService`
- Orchestrates entry creation in a single database transaction.
- Compares existing entries on identical source identity: returns existing entry if payload matches exactly, or fails with `:idempotency_conflict` if payload differs.
- Handles concurrent insertion collisions (`ActiveRecord::RecordNotUnique`) seamlessly.

### `Accounting::ReverseEntryService`
- Reverses an existing journal entry atomically by creating a new `JournalEntry` linked via `reversal_of_id`.
- Replicates all posting dimensions while negating `amount_cents` (`amount_cents * -1`).
- Reversal-of-reversal is forbidden. Idempotent on repeat execution.

## Invariants & Database Constraints

- Check constraints in PostgreSQL:
  - `check_accounts_account_type`: `account_type IN ('asset', 'liability', 'equity', 'income', 'expense')`
  - `check_postings_amount_cents_nonzero`: `amount_cents <> 0`
  - `check_journal_entries_source_id_positive`: `source_id > 0`
- Deletion Protection: Foreign keys on dimensions restrict cascading deletion of properties, rentable units, tenancies, or parties referenced in accounting postings.
