# RBS Signatures

This directory contains the type signatures used by [Steep](https://github.com/soutaro/steep) for static type checking.

## Directory Structure

| Directory | Ownership | Description |
|-----------|-----------|-------------|
| `sig/app/` | Hand-written | Application code signatures (services, queries, models, controllers) |
| `sig/shims/` | Hand-written | Narrow local signatures for Rails, gems, or dynamic APIs not covered by collection signatures |
| `sig/rbs_rails/` | Generated | Rails-aware signatures for models and route helpers (via `rbs_rails`) |

## Quick Start

### Running Type Checks

```bash
# Full type check (also runs in CI)
bundle exec steep check

# Validate RBS signatures for syntax/structural errors
bundle exec rbs validate
```

### Editor Integration (LSP)

Steep provides an LSP server for real-time type feedback in editors:

```bash
# Start the language server (VS Code, Neovim, etc.)
bundle exec steep langserver
```

**VS Code**: Install the [Steep extension](https://marketplace.visualstudio.com/items?itemName=soutaro.steep-vscode) for inline type errors, hover documentation, and completion.

**Neovim/other editors**: Configure your LSP client to use `bundle exec steep langserver` as the language server command.

## Adding Signatures for New Code

### 1. Scaffold a starting point

Use `rbs prototype` to generate initial RBS from Ruby source:

```bash
bundle exec rbs prototype rb app/services/my_domain/my_service.rb \
  > sig/app/services/my_domain/my_service.rbs
```

### 2. Refine the output

Prototyped signatures are a starting point, not a finished product. Review and refine:

- Add precise types for `.call` / `#call` method signatures
- Type initializer params and return values
- Use `untyped` sparingly at gem boundaries, but prefer concrete types for app-owned code
- Add nilability annotations where appropriate

### 3. Add to Steepfile

Add the new source file to the `check` list in `Steepfile`:

```ruby
check "app/services/my_domain/my_service.rb"
```

### 4. Verify

```bash
bundle exec steep check
```

## Maintenance

### After Schema Migrations

Regenerate Rails model and route helper signatures:

```bash
bin/rails rbs_rails:all
```

Then verify the regenerated output:

```bash
bundle exec steep check
```

> **PR review checklist**: If a PR includes a migration, verify that `rbs_rails` signatures have been regenerated.

### After Gem Updates

Refresh third-party collection signatures:

```bash
bundle exec rbs collection install
```

### Shim Conventions

- Keep shims small and focused on the specific API gap they fill.
- Add a comment at the top of each shim explaining why it exists and what upstream gap it covers.
- Prefer `untyped` at gem boundaries over attempting full gem typing.
- When upstream RBS support improves, remove the corresponding shim.

## Known Limitations

- **Dry gem typing** is approximate. `dry-monads`, `dry-struct`, and `dry-types` use heavy metaprogramming that RBS cannot express precisely. The shims in `sig/shims/dry_*.rbs` cover the methods used by `ServiceResult` and `IngestionResult` but do not model the full Dry DSL.
- **ActiveRecord relations** are typed as `untyped` in most hand-written signatures. The `rbs_rails` generated signatures provide some coverage but don't capture all dynamic query methods.
- **`prawn` and `hexapdf`** use `untyped` escape hatches at their API boundaries. Focus precision on the app-owned code that calls into them.
