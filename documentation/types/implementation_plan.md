# Implementation Plan: RBS and Steep Static Type Checking

## Overview

Add static type checking to the Rails application using RBS and Steep. The rollout establishes a small green baseline first, then expands coverage from stable domain code toward Rails edge layers. The goal is useful feedback in CI and editor tooling without requiring complete application typing on day one.

### Goals

- Add RBS and Steep tooling to the development and test bundle.
- Manage third-party gem signatures through RBS collection.
- Optionally generate Rails-aware signatures for models and route helpers with `rbs_rails` (contingent on Rails 8.1 compatibility).
- Add hand-written signatures for high-value app-owned service and query objects.
- Run `bundle exec steep check` in local CI and GitHub Actions.
- Keep the initial type-checking scope narrow enough to stay green and maintainable.
- Provide editor LSP integration via `steep langserver` for immediate developer feedback.

### Non-Goals

- Fully type every Rails controller, helper, and view-adjacent object in the first pass.
- Replace runtime tests with type checking.
- Refactor dynamic Rails or gem-heavy code only for type checker convenience.
- Type `Dry::Struct` value objects before the required shims are proven stable.

### Acceptance Criteria

- `bundle exec steep check` runs green for the initial checked scope.
- `bundle exec rbs validate` runs green.
- Third-party gem signatures are managed with `rbs_collection.yaml` and `rbs_collection.lock.yaml`.
- Hand-written application signatures live under `sig/app` or `sig/shims`.
- CI runs type checking without requiring full application type coverage on day one.
- `.gem_rbs_collection/` is ignored; RBS collection lockfiles are committed.

---

## Architecture

Type artifacts are separated by ownership:

```text
sig/
├── app/              # Hand-written signatures for application code
├── rbs_rails/        # Generated signatures from rbs_rails (if compatible)
├── shims/            # Local compatibility signatures for missing gem/Rails APIs
└── README.md         # Maintenance notes and local conventions
```

The `Steepfile` defines a conservative target starting with a small service slice that follows the `.call` convention. These services still touch Rails models, so the first green baseline needs minimal shims for the referenced models, `ActiveRecord` exceptions, and `ServiceResult`. `Dry::Struct` value objects are deferred until shims for `dry-monads`, `dry-struct`, and `dry-types` are proven.

Suggested initial target:

```ruby
target :app do
  signature "sig/app"
  signature "sig/shims"

  # Standard library modules used by checked files
  library "date"
  library "bigdecimal"

  # Start with one service and explicit local shims for its Rails boundary
  check "app/services/leases/save_service.rb"
end
```

Later PRs add `signature "sig/rbs_rails"`, more `check` entries, or split targets by layer.

---

## Design Decisions

| Question | Decision |
|---|---|
| How should rollout happen? | Incrementally, with a green baseline first and explicit scope expansion in later PRs. |
| What should be typed first? | A small service slice with `.call` conventions. These files have clear input/output contracts, but still need narrow shims for Rails/model boundaries. Dry gem value objects come later once shims exist. |
| Should generated signatures be committed? | Yes, if `rbs_rails` works. Commit generated output so CI and local checks are deterministic. Regenerate after every migration. |
| Should `.gem_rbs_collection/` be committed? | No. Ignore it and commit only the collection config and lockfile. |
| Where should local missing signatures go? | `sig/shims`, with comments explaining the upstream gap when useful. |
| How precise should first-pass types be? | Precise for app-owned service `.call` signatures and return types; permissive (`untyped`) at Rails and third-party gem boundaries. |
| Should controllers be typed first? | No. Controllers involve params, redirects, Turbo responses, and helpers, so they should come after services and queries. |
| What if `rbs_rails` doesn't support Rails 8.1? | Defer it entirely. The first Steepfile target works without `sig/rbs_rails/` signatures by using targeted shims instead. |
| How should `rbs` version conflicts be handled? | `rbs` 4.0.2 is already in `Gemfile.lock` as a transitive dependency of `ruby-lsp`. Use a permissive constraint (`gem "rbs", ">= 4.0"`) or omit it and rely on the transitive dependency. |

---

## Incremental PR Plan

## PR 1: Tooling Baseline and Ruby 4.0 Compatibility Spike

### Objective

Install Steep/RBS tooling, verify Ruby 4.0.3 compatibility, and create a minimal project structure without changing runtime behavior.

### Files

- `Gemfile`
- `Gemfile.lock`
- `.gitignore`
- `Steepfile`
- `rbs_collection.yaml`
- `rbs_collection.lock.yaml`
- `sig/README.md`
- `sig/shims/*.rbs`

### Tasks

1. Add the following gems to the `:development, :test` group with `require: false`:

   ```ruby
   # rbs is already a transitive dependency of ruby-lsp (4.0.2).
   # Use a permissive constraint to avoid version conflicts.
   gem "rbs", ">= 4.0", require: false
   gem "steep", require: false
   ```

2. Run:

   ```bash
   bundle install
   ```

3. **Ruby 4.0 compatibility spike**: Verify Steep installs and runs on Ruby 4.0.3:

   ```bash
   bundle exec steep version
   bundle exec rbs version
   ```

   If either tool fails to install or crashes on Ruby 4.0, stop here and evaluate alternatives (e.g., pinning to a pre-release version or waiting for upstream support). Document findings in `sig/README.md`.

4. Initialize RBS collection:

   ```bash
   bundle exec rbs collection init
   bundle exec rbs collection install
   ```

5. Add `.gem_rbs_collection/` to `.gitignore`.

6. Create the initial `sig/` directory structure:

   ```bash
   mkdir -p sig/app sig/shims
   ```

7. Create `sig/README.md` documenting:
   - Ownership of `sig/app` and `sig/shims`
   - `sig/rbs_rails` as an optional generated directory created in PR 3 if compatible
   - How to scaffold new signatures (`rbs prototype rb path/to/file.rb`)
   - Editor LSP integration (`steep langserver`)

8. Create a conservative `Steepfile` that checks one service file and uses explicit shims for Rails/model methods referenced by that file:

   ```ruby
   target :app do
     signature "sig/app"
     signature "sig/shims"

     library "date"
     library "bigdecimal"

     check "app/services/leases/save_service.rb"
   end
   ```

9. Add minimal shims so Steep can resolve all types referenced by `save_service.rb`. The full dependency list is:
   - `Lease` (class with `transaction`, `save!`, `errors`, attribute methods)
   - `ServiceResult` (`.success`, `.failure`)
   - `ActiveRecord::RecordInvalid` (exception class)
   - `Leases::ScheduledRentSyncService` (`.call` class method)

   Keep these intentionally narrow; the goal is a green baseline, not full Rails typing. Do not type `ScheduledRentsGenerator` yet; PR 1 only needs a shim for the sync service's public `.call` method.

### Verification

```bash
# Confirm .gitignore includes .gem_rbs_collection/
grep -q '.gem_rbs_collection' .gitignore && echo "OK" || echo "MISSING"

# Validate RBS signatures
bundle exec rbs validate

# Run type checking
bundle exec steep check
```

---

## PR 2: Typed Lease Services

### Objective

Add the first hand-written RBS signatures for service objects that follow the `.call` convention with clear input/output contracts.

### Why services first (not Dry value objects)

`ServiceResult`, `ServiceResultTypes`, and `IngestionResult` are subclasses of `Dry::Struct` using `Dry::Monads[:result]` and `Dry.Types()`. Every attribute, return value, and type constant comes from dynamic metaprogramming in the `dry-*` gems. Typing these requires substantial shims for `Dry::Struct`, `Dry::Types`, and `Dry::Monads::Result` — a significant upfront investment with uncertain payoff.

The lease services (`SaveService`, `ScheduledRentSyncService`) use the project's standard `.call` convention. `SaveService` returns a `ServiceResult`; `ScheduledRentSyncService` is side-effect oriented and returns `nil` or the result of its iteration. Their inputs and method shapes are clear and typeable even with `ServiceResult` itself left as `untyped` for now.

### Files

- `sig/app/services/leases/save_service.rbs`
- `sig/app/services/leases/scheduled_rent_sync_service.rbs`
- `sig/shims/service_result.rbs` (minimal shim: class declaration with `untyped` methods)
- `sig/shims/active_record.rbs` and focused model shims as needed
- `Steepfile`

### Tasks

1. Scaffold initial signatures using `rbs prototype`:

   ```bash
   bundle exec rbs prototype rb app/services/leases/save_service.rb > sig/app/services/leases/save_service.rbs
   bundle exec rbs prototype rb app/services/leases/scheduled_rent_sync_service.rb > sig/app/services/leases/scheduled_rent_sync_service.rbs
   ```

2. Refine the scaffolded output: type `.call` class methods, `#call` instance methods, initializer params, and return values according to the actual implementation.
3. Create a minimal `sig/shims/service_result.rbs` that declares `ServiceResult` with `untyped` methods so Steep doesn't error on return type references.
4. Add the service files to the Steep check target.
5. Fix any nilability or method-shape issues Steep reports.

### Verification

```bash
bundle exec steep check
bundle exec rspec spec/services/leases/
```

---

## PR 3: Rails Generated Signatures (Non-Blocking)

### Objective

Generate Rails-aware signatures for models and route helpers. **This PR is independent of PR 2 and can be done in parallel or deferred if `rbs_rails` is incompatible with Rails 8.1.3.**

### Files

- `Gemfile`
- `Gemfile.lock`
- `config/rbs_rails.rb`
- `lib/tasks/rbs.rake`
- `sig/rbs_rails/**/*`
- `Steepfile`

### Tasks

1. Add `rbs_rails` to the `:development, :test` group with `require: false`, then run `bundle install`.

2. Test `rbs_rails` generation:

   ```bash
   bin/rails g rbs_rails:install
   bin/rails rbs_rails:all
   ```

3. If generation fails or produces broken signatures for Rails 8.1.3:
   - Document the incompatibility in `sig/README.md`
   - Skip this PR entirely; the rest of the plan works without it
   - Open an upstream issue on `rbs_rails`

4. If generation succeeds:
   - Review generated signatures for obvious errors
   - Add small local shims in `sig/shims/` only where generated or collection signatures are missing required APIs
   - Add `signature "sig/rbs_rails"` to the Steepfile
   - Commit generated signatures

### Verification

```bash
bundle exec rbs validate
bundle exec steep check
```

---

## PR 4: Minimal Result Object Shims

### Objective

Create minimal signatures for the app-owned result objects that parsers and payment ingestion services depend on. This PR still avoids full Dry gem precision; it only establishes enough method shape for later parser and orchestrator typing.

### Files

- `sig/shims/dry_struct.rbs`
- `sig/shims/dry_types.rbs`
- `sig/shims/dry_monads.rbs`
- `sig/app/services/service_result.rbs`
- `sig/app/services/service_result_types.rbs`
- `sig/app/services/payment_ingestions/ingestion_result.rbs`
- `Steepfile`

### Tasks

1. Write minimal RBS shims for:
   - `Dry::Struct` base class and constructor
   - `Dry::Monads::Result`, `Dry::Monads::Result::Success`, and `Dry::Monads::Result::Failure`
   - `Dry::Types` module inclusion and the type constants this app references
   - Match dry-monads' runtime constant layout: `Success` and `Failure` live under `Dry::Monads::Result`, not directly under `Dry::Monads`.
2. Upgrade `sig/shims/service_result.rbs` to `sig/app/services/service_result.rbs`.
3. Add signatures for `ServiceResultTypes` and `PaymentIngestions::IngestionResult`.
4. Keep return payloads permissive where needed. The goal is to unblock method-shape and nilability checks for parsers and services, not to fully model Dry's DSL.
5. Add these result object files to the Steep check target only after the minimal shims validate.

### Verification

```bash
bundle exec steep check
bundle exec rspec spec/services/service_result_spec.rb spec/services/payment_ingestions/ingestion_result_spec.rb
```

---

## PR 5: Parsers and Query Objects

### Objective

Expand type checking to parsers and query objects after the result-object boundary has a minimal signature.

### Candidate Files

- `app/services/payment_ingestions/parsers/base.rb`
- `app/services/payment_ingestions/parsers/chase_statement.rb`
- `app/services/payment_ingestions/parsers/venmo.rb`
- `app/services/payment_ingestions/parsers/zelle.rb`
- `app/queries/**/*`
- `sig/app/services/payment_ingestions/parsers/*.rbs`
- `sig/app/queries/**/*.rbs`

### Tasks

1. Scaffold signatures with explicit output paths:

   ```bash
   bundle exec rbs prototype rb app/services/payment_ingestions/parsers/base.rb > sig/app/services/payment_ingestions/parsers/base.rbs
   bundle exec rbs prototype rb app/services/payment_ingestions/parsers/zelle.rb > sig/app/services/payment_ingestions/parsers/zelle.rbs
   ```

2. Add signatures for parser `#parse` methods, input types (raw text / IO), and output types.
3. Add signatures for query objects following the same pattern.
4. Introduce RBS type aliases only after repeated shapes emerge across signatures.
5. Add files to the Steep target in small batches (parsers first, then one query namespace at a time).

### Verification

```bash
bundle exec steep check
bundle exec rspec spec/services/payment_ingestions/parsers/ spec/queries/
```

---

## PR 6: Expand to Payment Ingestion Services

### Objective

Expand type checking into the payment ingestion service domain.

### Files

- `app/services/payment_ingestions/ingestion.rb`
- `app/services/payment_ingestions/confirm_service.rb`
- `app/services/payment_ingestions/update_service.rb`
- `app/services/payment_ingestions/upload_service.rb`
- `app/services/payment_ingestions/tenant_resolver.rb`
- `sig/app/services/payment_ingestions/*.rbs`

### Convention Note

`PaymentIngestions::Ingestion` is the main orchestrator for the domain (226 lines). Unlike other services, it does **not** follow the `self.call` class method convention — callers use `Ingestion.new.call(user:, pdf_path_or_io:, source:)` with an instance method directly. Its shim requirements are substantial: `HexaPDF::Document`, `Parsers::*`, `TenantResolver`, `PaymentDocument`, `PaymentIngestion`, and `Time.use_zone`. Start with `untyped` for `HexaPDF` and focus precision on the method signatures and control flow.

### Tasks

1. Scaffold signatures with explicit output paths:

   ```bash
   bundle exec rbs prototype rb app/services/payment_ingestions/confirm_service.rb > sig/app/services/payment_ingestions/confirm_service.rbs
   bundle exec rbs prototype rb app/services/payment_ingestions/ingestion.rb > sig/app/services/payment_ingestions/ingestion.rbs
   ```

2. Add precise signatures for `.call` / `#call`, initializer params, and return types.
3. For `ingestion.rb`, type the public `#call(user:, pdf_path_or_io:, source:)` method precisely. Use `untyped` for `HexaPDF::Document` and PDF IO internals.
4. Use `untyped` for ActiveRecord relations and gem-heavy internals where precision is not yet worth the cost.
5. Add files to the Steep target.

### Verification

```bash
bundle exec steep check
bundle exec rspec spec/services/payment_ingestions/
```

---

## PR 7: Refine Dry Gem Typing

### Objective

After the workflow is proven with result-object shims, parsers, and payment ingestion services, refine the Dry signatures where additional precision is worth the maintenance cost.

### Files

- `sig/shims/dry_struct.rbs`
- `sig/shims/dry_types.rbs`
- `sig/shims/dry_monads.rbs`
- `sig/app/services/service_result.rbs`
- `sig/app/services/service_result_types.rbs`
- `sig/app/services/payment_ingestions/ingestion_result.rbs`
- `Steepfile`

### Tasks

1. Review the minimal Dry shims created in PR 4 against the errors and false positives found in PRs 5 and 6.
2. Add precision only where it improves app-owned signatures or removes noisy `untyped` propagation.
3. Keep DSL-heavy Dry internals approximate. The goal is catching method-shape and nilability errors, not fully modeling Dry's metaprogramming.
4. Update result object signatures if the refined shims make safer payload types practical.

### Verification

```bash
bundle exec steep check
bundle exec rspec spec/services/service_result_spec.rb spec/services/payment_ingestions/ingestion_result_spec.rb
```

---

## PR 8: CI Integration

### Objective

Make type checking part of local and hosted CI once the initial scope is green.

### Files

- `.github/workflows/ci.yml`
- `config/ci.rb`

### Tasks

1. Add a GitHub Actions `typecheck` job:

   ```yaml
   typecheck:
     runs-on: ubuntu-latest
     steps:
       - uses: actions/checkout@v6
       - uses: ruby/setup-ruby@v1
         with:
           bundler-cache: true
       - run: bundle exec rbs collection install
       - run: bundle exec steep check
   ```

2. Cache `.gem_rbs_collection/` using `.ruby-version`, `Gemfile.lock`, and `rbs_collection.lock.yaml` as cache keys.
3. Add `Typecheck: Steep` step to `config/ci.rb`:

   ```ruby
   step "Typecheck: Steep", "bundle exec steep check"
   ```

4. **Note:** `config/ci.rb` currently runs `bin/rails test` (Minitest) instead of `bundle exec rspec`. Fix this discrepancy in the same PR or a preceding one:

   ```diff
   - step "Tests: Rails", "bin/rails test"
   + step "Tests: RSpec", "bundle exec rspec"
   ```

5. Keep CI scoped to already-green Steep targets.

### Verification

```bash
bin/ci
```

---

## PR 9: Gradual Coverage Expansion

### Objective

Expand type checking after the workflow is stable.

### Suggested Order

1. Remaining services (`expenses/`, `tenant_payments/`, `schedule_e_generator.rb`, `scheduled_rents_generator.rb`).
2. Jobs and mailers.
3. Models with important custom methods.
4. Controllers.
5. Helpers only if the signal is worth the annotation churn.

### Dependency Notes

- **`expenses/`**: `Expenses::SaveService` calls `Expenses::TenantChargeService.call(expense)` — a signature or shim for `TenantChargeService` is required.
- **`tenant_payments/`**: `TenantPayments::ReceiptPdfService` uses `prawn`/`prawn-table` for PDF generation — will need `untyped` shims for Prawn APIs.

### Tasks

1. Add one layer or domain slice at a time.
2. Keep each expansion independently green.
3. Update `sig/README.md` with known limitations and local conventions.
4. Regenerate `rbs_rails` signatures after schema-affecting migrations:

   ```bash
   bin/rails rbs_rails:all
   ```

### Verification

```bash
bundle exec steep check
bundle exec rspec
```

---

## Testing Strategy

- Use `bundle exec steep check` as the primary verification for static types.
- Use `bundle exec rbs validate` to catch invalid or stale signatures.
- Continue relying on RSpec for behavioral coverage; types complement but never replace tests.
- Pair each type-checking expansion with the relevant focused specs for that layer.
- Run the full suite before merging CI integration or broad coverage expansion.

---

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Steep may not fully support Ruby 4.0.3** — Ruby 4.0 is new and Steep may lag on syntax/semantics changes (frozen strings by default, `it` block parameter, etc.) | High | PR 1 includes an explicit compatibility spike. If Steep fails, the plan is paused until upstream support lands. |
| **`rbs_rails` may not support Rails 8.1.3** — especially newer APIs like `params.expect` | High | PR 3 is explicitly non-blocking. The rest of the plan works without generated Rails signatures. |
| **Dry gem typing is inherently difficult** — `dry-monads`, `dry-struct`, and `dry-types` rely on heavy metaprogramming that RBS cannot express precisely | Medium | Minimal shims are introduced in PR 4, then refined in PR 7 only where the added precision is worth the maintenance cost. |
| **`prawn` and `hexapdf` will require `untyped` escape hatches** | Low | Acceptable at gem boundaries; focus precision on app-owned code. |
| **Generated model signatures drift after migrations** | Medium | Document the `bin/rails rbs_rails:all` regeneration step. Enforce in PR review checklist. |
| **Overly broad initial coverage creates noisy diffs** | Medium | Start with 2-3 files per PR. Never expand faster than the team can review. |
| **`rbs` version conflict with `ruby-lsp`** | Low | Use permissive `gem "rbs", ">= 4.0"` constraint. Both tools need compatible versions. |
| **Type checking controllers too early** surfaces framework dynamism rather than application bugs | Low | Controllers are last in the expansion order. |

---

## Developer Workflow

### Editor Integration

Steep provides an LSP server for real-time type feedback in editors:

```bash
# VS Code: install the Steep extension, or configure the LSP manually
bundle exec steep langserver
```

This provides inline type errors, hover documentation, and completion for typed code. It works immediately once the `Steepfile` and signatures are in place.

### Scaffolding New Signatures

Use `rbs prototype` to generate initial RBS from Ruby source:

```bash
# Generate from Ruby source (produces a starting point, not final signatures)
bundle exec rbs prototype rb app/services/leases/save_service.rb > sig/app/services/leases/save_service.rbs
```

Review and refine the output — prototyped signatures are a starting point, not a finished product.

---

## Maintenance Notes

- Regenerate Rails signatures after migrations:

  ```bash
  bin/rails rbs_rails:all
  ```

- Refresh third-party signatures when gems change:

  ```bash
  bundle exec rbs collection install
  ```

- Keep shims small and documented. Each shim should have a comment explaining why it exists and what upstream gap it fills.
- Prefer improving app-owned signatures over chasing perfect signatures for dynamic Rails internals.
- Treat `untyped` as acceptable at gem boundaries, but avoid letting it spread through core domain objects.
- When adding a new service, add its RBS signature in the same PR. Update the Steepfile to include the new file.
