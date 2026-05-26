# Database Sharding Implementation Plan for Multi-Tenancy (Finalized & Implemented)

This document outlines the finalized architecture, configuration patterns, and implemented code structures used to transition the database from a single-tenant structure to a horizontally sharded multi-tenant structure using Rails 8's built-in multiple database and sharding features.

## Finalized Architecture

The application database is divided into two logical categories:
1. **Global Tables (Primary Database)**: Contains global authentication, user records, and session data.
   - `users` (landlords/agents)
   - `sessions` (authentication sessions)
2. **Sharded Tables (Horizontal Shards)**: Contains tenant-specific data (properties, leases, payments, etc.) physically isolated across shard databases (`shard_one`, `shard_two`).
   - `rental_properties`, `leases`, `lease_tenants`, `tenants`, `tenant_aliases`
   - `expenses`, `tenant_charges`, `tenant_payments`, `scheduled_rents`
   - `payment_documents`, `payment_ingestions`

```mermaid
graph TD
  subgraph Global Database (primary)
    User[users table]
    Session[sessions table]
  end

  subgraph Shard 1 Database (shard_one / default)
    P1[rental_properties]
    L1[leases]
    T1[tenants]
    Ex1[expenses]
    Pay1[tenant_payments]
  end

  subgraph Shard 2 Database (shard_two)
    P2[rental_properties]
    L2[leases]
    T2[tenants]
    Ex2[expenses]
    Pay2[tenant_payments]
  end

  User -->|shard: default| Shard1
  User -->|shard: shard_two| Shard2
```

---

## Technical Constraints & Design Patterns

### 1. Cross-Database Joins & Foreign Keys
- **No Cross-Database Foreign Keys**: Physical foreign keys referencing `users.id` have been removed in the migration (since PostgreSQL cannot enforce foreign key constraints across separate databases). Referental integrity is managed at the ActiveRecord layer.
- **No Cross-Database Joins**: Joins and preloading across the global and sharded databases (e.g., `User.joins(:rental_properties)`) are avoided. Queries are performed sequentially or preloaded into Ruby memory.

### 2. Shard Selection & Request Routing
- Shard routing is dynamically switched on each request in `ApplicationController` using an `around_action`.
- The user's assigned shard is determined at creation using a stable MD5 hash of their email address, ensuring an even distribution of tenants across active shards.

---

## Implemented Code & Configuration

### 1. Database Configuration (`config/database.yml`)
Mapped the primary connection and two horizontal shards across environments, isolating migration paths and schema dump files.

```yaml
development:
  primary:
    <<: *default
    database: yanushi_development
    migrations_paths: db/migrate
  shard_one:
    <<: *default
    database: yanushi_shard_one_development
    migrations_paths: db/shard_migrate
    schema_dump: shard_schema.rb
  shard_two:
    <<: *default
    database: yanushi_shard_two_development
    migrations_paths: db/shard_migrate
    schema_dump: shard_schema.rb
```

### 2. Abstract Sharding Class (`app/models/sharded_record.rb`)
All sharded models inherit from `ShardedRecord`. We established `:shard_one` as the fallback connection to ensure that test fixtures load and default queries resolve correctly outside switching blocks.

```ruby
class ShardedRecord < ActiveRecord::Base
  self.abstract_class = true

  establish_connection :shard_one

  connects_to shards: {
    default: { writing: :shard_one },
    shard_two: { writing: :shard_two }
  }
end
```

### 3. Automatic Shard Assignment (`app/models/user.rb`)
New users are assigned `default` or `shard_two` deterministically:

```ruby
class User < ApplicationRecord
  # ...
  validates :shard, presence: true
  before_validation :assign_shard, on: :create

  private

  def assign_shard
    self.shard ||= determine_shard
  end

  def determine_shard
    require "digest"
    shards = [ "default", "shard_two" ]
    index = Digest::MD5.hexdigest(email.to_s.strip.downcase).hex % shards.size
    shards[index]
  end
end
```

### 4. Controller Request Routing (`app/controllers/application_controller.rb`)
Switches the active shard connection for the lifecycle of each web request:

```ruby
class ApplicationController < ActionController::Base
  around_action :switch_shard

  private

  def switch_shard(&block)
    user = resume_session&.user
    shard = user&.shard || "default"

    ShardedRecord.connected_to(role: :writing, shard: shard.to_sym, &block)
  end
end
```

### 5. Job Execution Context (`app/jobs/ingest_payment_document_job.rb`)
Adapts background job execution to wrap performance logic in the appropriate tenant shard:

```ruby
class IngestPaymentDocumentJob < ApplicationJob
  queue_as :default

  def perform(payment_document_id, shard: "default")
    ShardedRecord.connected_to(role: :writing, shard: shard.to_sym) do
      payment_document = PaymentDocument.find(payment_document_id)
      # ... ingestion logic ...
    end
  end
end
```

---

## Verification & Validation

### Automated Tests
- Updated `test/fixtures/users.yml` to specify `shard: default` for test data so model instantiations succeed.
- Prepared database schemas for test runs:
  ```bash
  bin/rails db:schema:load:shard_one db:schema:load:shard_two
  RAILS_ENV=test bin/rails db:schema:load:shard_one db:schema:load:shard_two
  ```
- Executed the full unit and controller test suites successfully:
  ```bash
  bundle exec rails test # 177 runs, 621 assertions, 0 failures, 0 errors, 0 skips
  ```
- Executed the system test suites successfully:
  ```bash
  bundle exec rails test:system # 14 runs, 79 assertions, 0 failures, 0 errors, 0 skips
  ```

### Manual Verification
Confirmed tenant isolation by verifying that database records created under a `default` user are physically isolated from queries on `shard_two`, and vice versa.
