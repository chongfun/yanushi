# Yanushi UX Refresh: Milestone Implementation Plans

This plan is written to be executed step by step, including by an agent
with no prior knowledge of this codebase. Every class, route, partial, and
helper named here has been verified against the repository as of branch
`ux-refresh`. Section 0 records what exists today; if the code and this
document disagree, re-verify before proceeding and update the document.

Read together with:

- `documentation/ux-refresh/PRD.md` (requirements and rationale)
- `documentation/ux-refresh/mockups/` (normative HTML mockups; see its
  README for the file-by-milestone map)

## General implementation strategy

Implement the UX refresh as six stacked milestones. Each milestone must be
independently deployable and leave the application in a coherent state.

Across all milestones:

- keep existing domain services and accounting queries authoritative;
- introduce presentation/read-model queries only where a screen needs
  composition not already represented by one query;
- prefer ordinary Rails routes and actions;
- use Turbo Drive for navigation;
- use Turbo Frames only where preserving surrounding context materially
  improves the workflow;
- use Turbo Streams for mutation consequences;
- use Stimulus only for browser behavior;
- preserve existing URLs or redirect them;
- avoid database migrations (no UX requirement here needs persisted state);
- follow mockup visual hierarchy and component recipes rather than inventing
  new styling, adapting structure where needed for semantic HTML, Rails form
  builders, Hotwire mechanics, and accessibility.

### Visual system decision

The refresh replaces daisyUI as the visible design language with a small
first-party layer ("Yanushi UI"): Tailwind v4 utilities for layout plus the
component classes in `documentation/ux-refresh/mockups/yanushi-ui.css`
(`.yn-btn*`, `.yn-status`, `.yn-table`, `.yn-tabs`, `.yn-menu`,
`.yn-alert*`, `.yn-empty*`, `.yn-nav-link`, `.yn-surface`, `.yn-count`,
restyled `.modal-*`). No new CSS or JS framework is added.

The daisyUI plugin stays installed through Milestones 1 to 5 so untouched
pages keep rendering, and is removed in Milestone 6 once no view references
a daisyUI class. New and redesigned views must not use daisyUI classes.

---

# 0. Ground truth: what exists today (verified)

## 0.1 Stack

- Rails 8.1.3, PostgreSQL, importmap-rails (no Node, no package.json).
- turbo-rails 2.0.23, stimulus-rails; Propshaft with
  `stylesheet_link_tag :app` (bulk include of `app/assets/**/*.css`).
- Tailwind v4 via tailwindcss-rails 4.6.0. Input file:
  `app/assets/tailwind/application.css`. There is no tailwind.config.js.
- daisyUI 5.5.19 vendored at `app/assets/tailwind/plugins/daisyui.mjs`,
  loaded via `@plugin ... { themes: silk --default; }`. Single light theme.
- Auth: Rails 8 generated authentication (not Devise). `resource :session`,
  `resources :passwords`. The current-user accessor `authenticated_user`
  is a PRIVATE controller method and is NOT available in views. Views may
  use `Current.user` (`Current` delegates `user` to `session`, allow_nil).
  The user's address field is `user.email`.
- There is no sign-out link anywhere in the current UI, and no user menu.

## 0.2 Queries (exact names; all are directory-namespaced)

Accounting (`app/queries/accounting/`):

| Class | Interface | Returns |
|---|---|---|
| `Accounting::PropertyLedgerQuery` | `.call(property:, from:, through:, year:, date_range:)` | `Array[Accounting::ActivityRow]`, newest first |
| `Accounting::PropertySummaryQuery` | same kwargs | `SummaryResult` Data (income, expenses, net, cash movement, receivable, deposits held, by-account breakdowns) |
| `Accounting::ActiveYearsQuery` | `.call(property:, additional_years: [])` | sorted `Array[Integer]`, always includes current year |
| `Accounting::DateRange` | `.parse(params)` (positional hash), `#valid?`, `#range`, `#as_of` | value object |
| `Accounting::TenancyBalanceQuery` | `.call(tenancy:, as_of: nil)` → BigDecimal; `.balance_cents_as_of` → Integer. No instance `#call` | balance |
| `Accounting::TenantReceivableActivityQuery` | `.call(tenancy:, from:, through:, year:, date_range:)` | `StatementResult` (opening/closing cents + `StatementRow`s with running balance, party, source, reversal, lifecycle_status) |
| `Accounting::RecentTenantReceivableActivityQuery` | `.call(tenancy:, limit: 5, as_of:)` | `Array[StatementRow]`, newest first |
| `Accounting::SecurityDepositBalanceQuery` | `.call(tenancy: nil, property: nil, user: nil, as_of: nil)` | Integer cents (liability, sign-inverted) |
| `Accounting::TenancyActivityQuery` | `.call(tenancy:, ...)` | `Array[ActivityRow]` |
| `Accounting::AccountActivityQuery` / `AccountBalanceQuery` | account drilldowns | see files |
| `Accounting::ActivityProjector` | `.project(journal_entry, as_of:)` | one `ActivityRow` (maps event_type to human label, handles reversals/lifecycle) |
| `Accounting::ActivityRow` | Data: id, journal_entry, occurred_on, kind, label, description, amount_cents, property, rentable_unit, tenancy, party, source, reversal, corrected, lifecycle_status | row type |

Others:

- `Dashboards::PropertySummariesQuery`: `#initialize(properties:)`, `#call`
  returns an Array of plain hashes (`:property, :income, :expenses,
  :net_income, :tenancy_balances, :lease_balances`). Replaced in M2.
- `ImportedTransactions::IndexQuery`: `#initialize(user:)`,
  `#call(page:, per_page:)` returns a Data with
  `reviewable_transactions, confirmed_transactions, processing_documents,
  failed_documents, page, per_page, total_pages, total_confirmed_count`.
  Split in M4.
- `ImportedTransactions::FormDataQuery`: parties/tenancies + maps for the
  review form.
- `Tenancies::BalanceQuery` is a one-line alias of
  `Accounting::TenancyBalanceQuery`.
- `TaxReporting::ScheduleEQuery`: `.call(property:, tax_year: nil)` returns
  `TaxReporting::ScheduleEResult` with `status` (`:ok` or
  `:tax_profile_required`), `rents_received_cents`,
  `expenses_by_category_cents`, `total_expenses_cents`, `net_income_cents`,
  `review_items` (each with `resolved?`/`unresolved?`), drilldowns, and
  helpers `has_unresolved_reviews?`, `tax_profile_configured?`.
- `TaxReporting::ScheduleEFormDefinition.for(tax_year)` supplies line
  numbers/labels; `TaxReporting::TaxYear.parse` validates years.
- `ScheduleEGenerator` is a TOP-LEVEL service
  (`app/services/schedule_e_generator.rb`): `.new(property, year).call`
  returns PDF bytes; raises `TemplateMissingError`,
  `TaxProfileRequiredError`, `TaxReviewRequiredError`.

## 0.3 Domain state machines relevant to the UX

`ImportedTransaction.status` enum (string): `pending, matched, unmatched,
ambiguous, confirmed, failed`. "Reviewable" is the scope
`where(status: %w[matched unmatched ambiguous failed])`, mirrored by
`#reviewable?`. `#confirmable?` further requires matched party +
tenancy, positive amount, date, a known `transaction_kind`
(`tenant_receipt` or `security_deposit`), payment method for receipts, and
an existing security deposit for deposit kind. Confirmed records are
immutable (update/destroy blocked at the model).

`SourceDocument.status` enum: `processing, success, failed` (three values
only). `document_type`: `unknown, zelle, venmo, chase_statement`.
Uploads enqueue `IngestSourceDocumentJob`; failures write `error_message`
onto the document. `SourceDocuments::RetryService` re-opens failed docs.
There is no Turbo Stream broadcasting anywhere in the app today; Action
Cable is wired (solid_cable in production, async in dev) but unused.

## 0.4 Existing frontend infrastructure

Stimulus controllers (eager-loaded, all load on every page):
`date_range_filter` (year vs from/through mutual exclusion + auto-submit),
`imported_transaction_form`, `modal`, `nested_form`, `property_units`
(dependent unit select), `tax_profile_form` ("other" toggle), `toast`
(auto-dismiss), `turbo_confirm` (Turbo.setConfirmMethod bridge), `hello`
(dead scaffold code).

Modal system: one global `<dialog id="modal" class="modal-dialog">` in the
layout hosting `<turbo-frame id="modal-frame">`. Trigger links carry
`data: { turbo_frame: "modal-frame" }`; the response wraps content in
`<turbo-frame id="modal-frame" data-modal-title="...">`; `modal_controller`
opens on `turbo:frame-load` and intercepts a custom `close_modal` stream
action. A second `<dialog id="confirm-modal">` backs `data-turbo-confirm`.
Flash: `<div id="flash-messages">` + `shared/_toast` (locals `type:`,
`message:`), appended via `turbo_stream.append("flash-messages", ...)`.

Views: no shared page-header/tabs/empty-state partials exist. Helpers are
almost all empty; the two real ones (`PropertiesHelper`,
`ImportedTransactionsHelper`) do domain lookups. No ViewComponent/Phlex.

## 0.5 Known defects the refresh will encounter (fix at the noted milestone)

1. `receipts/new.html.erb` has NO `modal-frame` wrapper, so the
   "Record Payment" modal trigger in `properties/_financials.html.erb`
   requests a frame the response does not contain. (Fix in M3.)
2. `ReceiptsController#create` success streams
   `turbo_stream.update("flash", partial: "shared/flash", locals: { notice: ... })`.
   The DOM id is `flash-messages`, and `shared/_flash` ignores a `notice`
   local, so this is a double no-op. It also does not close the modal.
   (Fix in M3 by adopting the standard dialog contract.)
3. `ReceiptsController#create` duplicates its failure turbo_stream five
   times. (Consolidate in M3.)
4. `modal_controller.close()` clears frame innerHTML but not the frame's
   `src`, so re-clicking the same trigger may not re-fetch/reopen.
   (Fix in M1.)
5. The layout's modal `<h2 id="modal-title">` is not linked to the dialog
   via `aria-labelledby`; the layout also declares
   `data-modal-target="frame"` which the controller does not use.
   (Fix in M1.)
6. `properties/schedule_e.html.erb` (306 lines) renders inside the 480px
   modal frame. (Becomes a full page in M5; do not "fix" earlier.)
7. `properties/_financials.html.erb` re-runs `Accounting::DateRange.parse`,
   `ActiveYearsQuery`, `PropertyLedgerQuery`, and `PropertySummaryQuery`
   from ERB via `local_assigns` fallbacks. (Removed in M2.)
8. Duplicate route `get "dashboards/index"` alongside `root`. (Remove in
   M1; nothing links to it.)
9. Desktop and mobile navbars list items in different orders. (Moot once
   the navbar is replaced in M1.)
10. Incomplete lease→tenancy rename: `properties/_lease_balances.html.erb`,
    `#active_lease_balances`, `:lease_balances` hash keys,
    `active_lease_for`/`active_leases_for` helper aliases. (Delete in M6,
    or earlier when the surrounding code is replaced.)
11. `receipts`, `expenses`, `properties`, `tenancies`, `parties`,
    `accounts` indexes are unpaginated. (Receipts/expenses get pagination
    in M5; the audit in M6 bounds the rest as needed.)

## 0.6 Quality gates every milestone must pass

`bin/ci` is canonical (see `config/ci.rb`). Its steps:

```bash
bin/rubocop
bundle exec steep check
bin/bundler-audit
bin/importmap audit
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
bundle exec rspec
env RAILS_ENV=test bin/rails db:seed:replant
```

Non-negotiable constraints that affect UX work specifically:

- **Steep type-checks `app/helpers`, `app/controllers`, `app/queries`,
  `app/services`, `app/jobs`, `app/models`.** Every new Ruby class or
  helper needs a matching `.rbs` under `sig/app/...`. Scaffold with
  `bundle exec rbs prototype rb <file> > sig/app/<path>.rbs`, then refine.
  Read `sig/README.md` first.
- **After any route change, run `bin/rails rbs_rails:all`** to regenerate
  model and route-helper signatures, then `bundle exec rbs validate`.
- **SimpleCov enforces 95% line / 90% branch** (spec_helper + CI). Every
  new helper/controller/query needs specs sufficient to hold the gate.
- **System specs default to rack_test.** A `js: true` metadata switches to
  Selenium headless Chrome (configured in
  `spec/support/system_spec_helper.rb` but unused today, and CI installs
  no Chrome explicitly; GitHub ubuntu runners ship Chrome). Milestone 1
  must prove this path works with one small `js: true` spec before later
  milestones depend on it. If CI lacks Chrome, add a setup step
  (`browser-actions/setup-chrome`) to `.github/workflows/ci.yml` in the
  same PR.
- New JS libraries would need `bin/importmap pin` + vendoring; this plan
  requires none.

---

# Milestone 1: UX Foundation and Application Shell

Mockups: `app-shell.html`, `styleguide.html`.

## Goal

Replace the resource-oriented shell with the final information
architecture while changing as little workflow behavior as possible.

## 1. Adopt the Yanushi UI CSS layer

Copy the contents of `documentation/ux-refresh/mockups/yanushi-ui.css`
into `app/assets/tailwind/application.css`, below `@import "tailwindcss";`
and the existing `@plugin` block, REPLACING the current hand-written
`.modal-*` rules (the new file restyles the same class names). Keep the
daisyUI `@plugin` block for now.

The `:root` custom properties and `.yn-*` classes are the design tokens.
Do not add new colors or component classes without updating the mockup CSS
and `styleguide.html` in the same commit.

## 2. Establish stable top-level destinations

```ruby
root "dashboards#index"

get "portfolio", to: "portfolio#show",              as: :portfolio
get "money",     to: "money#show",                  as: :money
get "inbox",     to: "imported_transactions#index", as: :inbox
get "reports",   to: "reports#show",                as: :reports
```

Also delete the dead `get "dashboards/index"` line. Keep every existing
resource route. Run `bin/rails rbs_rails:all` after editing routes.

New thin controllers (each with an RBS sig and request specs):

- `PortfolioController#show`: landing that renders the property index
  content is deferred to M2; for M1 render a simple page linking to
  Properties (dominant), Tenancies, Parties.
- `MoneyController#show`: for M1, links to Receipts and Expenses. The
  Activity tab arrives in M5; do not show a disabled placeholder tab.
- `ReportsController#show`: for M1, a simple per-property list linking to
  each property's existing `schedule_e_property_path`. Replaced in M5.

All three scope data through `authenticated_user` exactly like existing
controllers.

## 3. Replace the global navbar with the shell

Rebuild `app/views/layouts/application.html.erb` to the structure in
`app-shell.html`:

```erb
<body class="yn-body">
  <%= render "shared/skip_link" %>
  <div class="min-h-screen lg:flex">
    <%= render "shared/sidebar" %>
    <div class="flex-1 min-w-0">
      <%= render "shared/mobile_topbar" %>
      <main id="main" class="px-4 py-6 sm:px-6 lg:px-10 lg:py-8">
        <%= yield %>
      </main>
    </div>
  </div>
  <%= render "shared/flash" %>
  <%# modal + confirm dialogs: keep, with the M1 fixes below %>
</body>
```

New partials (markup from `app-shell.html`):

```text
app/views/shared/_sidebar.html.erb
app/views/shared/_mobile_topbar.html.erb
app/views/shared/_navigation.html.erb   (nav list used by both sidebar and drawer)
app/views/shared/_navigation_drawer.html.erb
app/views/shared/_inbox_badge.html.erb
app/views/shared/_mobile_inbox_badge.html.erb
```

Delete `app/views/shared/_navbar.html.erb` once nothing renders it.

Notes:

- The old layout's `container mx-auto px-4 py-8 max-w-7xl` wrapper goes
  away; pages own their max-width (`max-w-5xl` default, `max-w-6xl` for
  Inbox, `max-w-4xl` for Schedule E), per the mockups. Old, not-yet-
  redesigned views will render acceptably inside the new `main`; where an
  old view relied on the container, wrap it minimally rather than
  redesigning it early.
- The sidebar user row uses `Current.user&.email` and
  `button_to "Sign out", session_path, method: :delete` (this is the first
  sign-out affordance in the app; `SessionsController#destroy` already
  exists). Do NOT call `authenticated_user` from views; it is private.
- The Inbox badge in `_navigation.html.erb` renders
  `shared/_inbox_badge.html.erb` with stable, distinct target IDs
  (`sidebar_inbox_badge` in the sidebar and `drawer_inbox_badge` in the
  drawer; `_mobile_topbar.html.erb` contains `mobile_inbox_badge`). All three
  target wrappers persist in the DOM even when the count is zero (styled
  `hidden`), guaranteeing Turbo Stream replacements always find their target.
  Compute the count with `inbox_reviewable_count` in `NavigationHelper`,
  memoized per request so the three rendered locations execute a single COUNT.
- The layout's `<% if content_for?(:breadcrumbs) %>` block is removed.
  Breadcrumbs become the page-header eyebrow (see §5) on the pages that
  need them; pages keep their existing `content_for :breadcrumbs` blocks
  until each is redesigned, so delete the blocks opportunistically as
  views are touched, and finally in M6.

## 4. Navigation helper

`app/helpers/navigation_helper.rb` (+ `sig/app/helpers/navigation_helper.rbs`
+ `spec/helpers/navigation_helper_spec.rb`):

```ruby
module NavigationHelper
  PRIMARY_ITEMS = [
    { key: :overview,  label: "Overview",  path_helper: :root_path },
    { key: :portfolio, label: "Portfolio", path_helper: :portfolio_path },
    { key: :money,     label: "Money",     path_helper: :money_path },
    { key: :inbox,     label: "Inbox",     path_helper: :inbox_path },
    { key: :reports,   label: "Reports",   path_helper: :reports_path }
  ].freeze

  def active_primary_navigation_key
    # maps request.path prefixes to keys
  end
end
```

Prefix mapping to pin with specs:

- `/` exact → `:overview`
- `/portfolio`, `/properties` (except `/properties/:id/schedule_e*`),
  `/tenancies`, `/parties`, `/rentable_units` → `:portfolio`
- `/money`, `/receipts`, `/expenses`, `/charges`,
  `/security_deposit_transactions` → `:money`
- `/inbox`, `/imported_transactions`, `/source_documents` → `:inbox`
- `/reports` and `/properties/:id/schedule_e*` → `:reports`
- `/accounts`, `/journal_entries` → secondary `:accounting`

Render `aria-current="page"` on the active `yn-nav-link`.

## 5. Shared page primitives

Create, with markup lifted from the mockups:

```text
app/views/shared/_page_header.html.erb
app/views/shared/_tabs.html.erb
app/views/shared/_empty_state.html.erb
app/views/shared/_status.html.erb
```

Interfaces (Rails partial locals; use `capture` blocks for action slots):

```erb
<%# shared/_page_header: locals
     title:   (String, required)
     eyebrow: (html/String, optional)  breadcrumb-style context line
     meta:    (html/String, optional)  metadata line under the title
     actions: (html, optional)         right-aligned buttons/menu
     tabs:    (html, optional)         rendered beneath, full width %>

<%# shared/_tabs: locals
     items: Array of { label:, path:, current: bool, count: Integer|nil } %>

<%# shared/_status: locals
     tone: :ok | :warn | :danger | :neutral
     text: String %>

<%# shared/_empty_state: locals
     title:, body:, action: (html, optional) %>
```

Example use:

```erb
<%= render "shared/page_header",
      title: @property.address,
      eyebrow: link_to("Portfolio", portfolio_path),
      meta: property_meta_line(@property),
      actions: capture { render "properties/header_actions", property: @property },
      tabs: capture { render "shared/tabs", items: property_tab_items(@property) } %>
```

Add a `FormattingHelper` (name it `MoneyHelper` if preferred) with specs
and sigs; this is the single home for money/date presentation:

```ruby
format_money_cents(cents)      # 240000 → "$2,400.00" (always cents)
signed_money_cents(cents)      # receipts render "−$2,000.00" (U+2212)
balance_phrase_cents(cents)    # 35000 → "$350.00 due"
                               # -8000 → "$80.00 credit"
                               # 0     → "Settled"
```

Views must not hand-roll currency strings from this point on.

## 6. Button and status conventions

Encoded in `yanushi-ui.css` + `styleguide.html`. Enforcement rules for
every redesigned view:

- one `.yn-btn-primary` per screen, matching the page's primary purpose;
- `.yn-btn-secondary` for normal alternatives, `.yn-btn-ghost` for quiet
  ones, `.yn-btn-danger` only inside confirm dialogs;
- destructive entries live at the bottom of an overflow `.yn-menu` behind
  a separator and always go through `data-turbo-confirm`;
- status uses `shared/_status`; ordinary metadata is plain text with `·`
  separators, no badges;
- no emoji in labels (remove `＋`/`📋` as views are touched).

## 7. Mobile navigation drawer

`app/javascript/controllers/navigation_drawer_controller.js`, owning only:
open (`showModal()`), close, Escape (native to `<dialog>`), focus restore
to the trigger, and body scroll lock. The drawer `<dialog>` renders
`shared/_navigation` (same partial as the sidebar). No navigation state
lives in JS.

Delete `hello_controller.js` in this milestone (dead code).

## 8. Modal infrastructure fixes (defects 4 and 5)

In `modal_controller.js`:

- in `close()`, also `frame.removeAttribute("src")` so the same trigger
  reopens reliably;
- keep the `close_modal` custom stream action; it becomes the standard
  close mechanism for every dialog flow in M3+.

In the layout:

- add `aria-labelledby="modal-title"` to `<dialog id="modal">`;
- drop the unused `data-modal-target="frame"` attribute or add `frame` to
  the controller's declared targets (pick one; the former is smaller).

## 9. Overflow menu controller

`app/javascript/controllers/menu_controller.js`: progressive enhancement
over the `<details>`-based `.yn-menu` markup (close on Escape, close on
outside click, `aria-expanded` sync). The menu works without JS via
`<details>`; the controller only improves dismissal behavior.

## 10. Tests

Request specs: `/portfolio`, `/money`, `/inbox`, `/reports` (auth required,
200 for the owner, correct nav highlighted). Helper specs: the
`NavigationHelper` prefix table and every `FormattingHelper` function
(these are pure and cheap to cover; the coverage gate demands it).

System specs:

- shell navigation (rack_test): sign in, see all five destinations plus
  Accounting, visit each, assert `aria-current` moves;
- one `js: true` smoke spec: open the mobile drawer at a narrow window
  size, navigate, assert focus returns. This spec exists to prove the
  Selenium path in CI. If CI cannot run Chrome, fix CI in this PR (see
  §0.6), because M3 and M4 need `js: true` coverage.

## Suggested commits

1. `Add Yanushi UI component layer and design tokens`
2. `Add user-oriented application destinations`
3. `Replace resource navbar with sidebar application shell`
4. `Add shared page primitives and formatting helpers`
5. `Fix modal frame reopen and dialog labelling`
6. `Cover application shell navigation`

## Done when

- global navigation is exactly Overview / Portfolio / Money / Inbox /
  Reports, with Accounting secondary and a working sign-out;
- all existing workflows remain reachable;
- desktop and mobile navigation work, keyboard included;
- new entry routes have stable URLs and request specs;
- one green `js: true` system spec runs in CI;
- `bin/ci` passes, including Steep with new sigs.

---

# Milestone 2: Overview and Portfolio

Mockups: `overview.html`, `portfolio.html`, `property-overview.html`,
`property-tenancies.html`, `property-activity.html`, `property-tax.html`.

## Goal

Make Overview answer "what needs attention?" and split Property into
Overview / Tenancies / Activity / Tax contexts.

## 1. Batch tenancy balances

`Accounting::TenancyBalanceQuery` computes one tenancy at a time. Add:

```text
app/queries/accounting/tenancy_balances_query.rb
```

`.call(tenancies:, as_of: nil)` → `Hash[Integer, Integer]` (tenancy_id →
balance_cents) in one grouped query over postings, matching the account
and sign conventions of `TenancyBalanceQuery` (assert equality against it
in specs). Used by Overview, the property Overview and Tenancies tabs, and
the Portfolio index.

## 2. Overview read models

```text
app/queries/dashboards/overview_query.rb
app/queries/dashboards/attention_query.rb
app/queries/dashboards/portfolio_summary_query.rb
app/queries/dashboards/recent_activity_query.rb
```

`Dashboards::OverviewQuery.call(user:)` returns:

```ruby
OverviewResult = Data.define(
  :attention_items,   # Array[AttentionItem]
  :portfolio_summary, # PortfolioSummary
  :properties,        # Array[PropertyRow]
  :recent_activity    # Array[Accounting::ActivityRow] (bounded, ~8)
)
```

`Dashboards::AttentionQuery` returns typed items:

```ruby
AttentionItem = Data.define(:kind, :title, :description, :path, :severity)
# kind: :inbox_review | :import_failed | :balance_due
# severity: :warn | :danger
```

Sources, all cheap single queries:

- `:inbox_review`: `ImportedTransaction.reviewable` count (+ newest row
  for the description), path `inbox_path`;
- `:import_failed`: `SourceDocument.failed` rows, path
  `inbox_path(view: "processing")`. M2's current Inbox ignores the view parameter
  but still presents processing/failed uploads at the top; M4 makes `processing` a
  distinct server-addressable Inbox state.
- `:balance_due`: any tenancy with a positive receivable balance as of today,
  including active, upcoming, and past tenancies via `Accounting::TenancyBalancesQuery`.
  Non-active tenancies carry explicit lifecycle labels (`"Upcoming tenancy · balance outstanding"`,
  `"Past tenancy · balance outstanding"`). Receivables accounting lifecycle is independent of
  lease occupancy lifecycle: unpaid debt remains actionable and must not disappear upon lease
  termination, while charges created prior to commencement are surfaced.

Do NOT add Schedule E attention items in M2: computing
`TaxReporting::ScheduleEQuery` per property on every dashboard load is too
expensive. M5's `Reports::ScheduleEStatusesQuery` may feed an attention
item later if it proves cheap enough; note it as a follow-up, not a
blocker. Do not invent overdue thresholds; "balance due" is what the
domain knows.

`Dashboards::PortfolioSummaryQuery` returns only what Overview shows:
property count, unit count, occupied/vacant counts, aggregate amount due
(sum of positive balances), and YTD income/expenses/net.
The YTD calculation must use an explicit range bounded through today:

```ruby
ytd_range = Accounting::DateRange.new(
  from: Date.current.beginning_of_year,
  through: Date.current
)
Dashboards::PortfolioSummaryQuery.call(user: current_user, date_range: ytd_range)
```

(Reuse the account predicates of `Accounting::PropertySummaryQuery` bounded by
`date_range`; if summing `PropertySummaryQuery` across properties as an initial
implementation, pass `date_range: ytd_range` to each property call so future-dated
postings never leak into portfolio YTD totals).

`Dashboards::RecentActivityQuery` returns approximately 8 most recent
portfolio-wide journal events through `Date.current`, newest first:

```ruby
Dashboards::RecentActivityQuery.call(
  user: current_user,
  through: Date.current,
  limit: 8
)
```

Eager-loads the complete association graph before projection to prevent N+1 queries on the dashboard:

```ruby
user.journal_entries
  .where("occurred_on <= ?", through)
  .order(occurred_on: :desc, id: :desc)
  .limit(limit)
  .includes(
    :source,
    :reversal,
    postings: [:account, :property, :rentable_unit, :tenancy, :party],
    reversal_of: [
      :source,
      :reversal,
      postings: [:account, :property, :rentable_unit, :tenancy, :party]
    ]
  )
```

Projects each entry through `Accounting::ActivityProjector.project(entry, as_of: through)`:

```ruby
entries.map do |entry|
  Accounting::ActivityProjector.project(entry, as_of: through)
end
```

Passing explicit `through: Date.current` guarantees that future-dated entries
are excluded from the preview, while previous-year events remain eligible after
January 1. Passing `as_of: through` to `ActivityProjector` ensures that if an entry
dated before `through` has a reversal dated after `through`, the original entry
remains `:active` as of that query date rather than reflecting future reversal state.

Delete `Dashboards::PropertySummariesQuery` once `dashboards/index` no
longer uses it (remove its spec and sig in the same commit).

## 3. Rebuild `dashboards/index`

Copy structure from `overview.html`: Attention (rows link to `item.path`),
portfolio summary strip, compact property rows, recent activity table.
Zero attention items renders the single caught-up line, not a box.

## 4. Property contextual routes

```ruby
resources :properties do
  scope module: :properties do
    resources :tenancies, only: :index
    resource :activity, only: :show
    resource :tax, only: :show
  end
  # existing nested resources and schedule_e member routes stay unchanged
end
```

Controllers: `Properties::TenanciesController`,
`Properties::ActivitiesController`, `Properties::TaxesController`. Each
loads the property through `authenticated_user.properties.find`, exactly
like `PropertiesController#set_property`. Run `bin/rails rbs_rails:all`.

## 5. Property header and tabs

```text
app/views/properties/_header.html.erb   (uses shared/_page_header)
```

Rendered by all four tab actions. Tabs via `shared/_tabs`. Header actions:
overflow menu (Edit property, Add unit, Delete property…) plus primary
"Record expense" linking to `new_property_expense_path(@property)` as a
NORMAL page navigation in this milestone (see §8).

## 6. Simplify Property Overview (`properties#show`)

Remove from `properties#show`: ledger date-range filter parameters (`from`,
`through`, `year`), `ActiveYearsQuery`, and Schedule E state (all moved to the
Activity and Tax tabs). Load for Overview:

- units + active tenancies (eager-loaded: `rentable_units.includes(tenancies: :parties)`);
- tenancy balances via `Accounting::TenancyBalancesQuery`;
- deposits held via `Accounting::SecurityDepositBalanceQuery.call(property:)`;
- YTD summary through today via:
  ```ruby
  ytd_range = Accounting::DateRange.new(
    from: Date.current.beginning_of_year,
    through: Date.current
  )
  Accounting::PropertySummaryQuery.call(property: @property, date_range: ytd_range)
  ```
  (passing explicit `through: Date.current` ensures future-dated charges/postings
  do not leak into YTD income/expenses);
- 5 recent activity rows through today via:
  ```ruby
  recent_range = Accounting::DateRange.new(through: Date.current)
  Accounting::PropertyLedgerQuery.call(
    property: @property,
    date_range: recent_range,
    limit: 5
  )
  ```
  (add an explicit `limit:` kwarg to `PropertyLedgerQuery` rather than slicing
  in Ruby; extend its sig and specs; passing `through: Date.current` without a
  lower bound ensures December activity remains visible in the 5-row preview
  after January 1).

View per `property-overview.html`. Delete
`properties/_lease_balances.html.erb` and the `#active_lease_balances`
region here (its content is superseded by the units table balance column).

## 7. Property Tenancies and Activity

`Properties::TenanciesController#index`: current + upcoming + past sections per
`property-tenancies.html`, balances batched, `includes(:parties, :tenancy_parties,
:rentable_unit, :rent_terms)`.

`Properties::ActivitiesController#show` owns what `show` gave up:
`Accounting::DateRange.parse(params)`, `ActiveYearsQuery`,
`PropertyLedgerQuery`, `PropertySummaryQuery`. View per
`property-activity.html`; the existing `date_range_filter` Stimulus
controller drives the filter form unchanged. Rows link to source records
and journal entries.

Then delete `properties/_financials.html.erb` (defect 7) and rework its
one remaining consumer: `ExpensesController#create` currently streams
`update("property_financials", ...)`. In M2, change expense creation
initiated from property context to a plain HTML redirect to
`property_activity_path(@property)` with a flash toast, and remove the
`close_modal`/`property_financials` stream response (the dialog trigger is
gone from the property page; `expenses/new` remains a normal page. Its
`modal-frame` wrapper and `expenses/_modal_form.html.erb` are deleted with
it). The dialog treatment returns in M5 under the M3 contract.
`ReceiptsController#create`'s `property_financials` stream branch is dead
after this change; strip it when touching the file in M3.

## 8. Property Tax tab

`Properties::TaxesController#show` per `property-tax.html`: year param parsed
via `TaxReporting::TaxYear.parse(params[:year], default: default_year) || TaxReporting::TaxYear.new(default_year)`
(ensuring invalid non-blank inputs such as `'abc'` fall back cleanly to
`default_year`), profile via `@property.tax_profile_for(year)`, readiness via
`TaxReporting::ScheduleEQuery.call(property:, tax_year:)` (one property,
one year: acceptable cost). Links into the existing
`schedule_e_property_path(@property, year:)` and
`edit_property_tax_profile_path`. Do not reproduce the worksheet.

## 9. Portfolio landing

`PortfolioController#show` replaces the M1 placeholder with the property
table from `portfolio.html` (balances batched; occupancy from loaded
units/tenancies). Tabs link to the existing `tenancies_path` and
`parties_path`; restyle those two index views to the shared vocabulary
(header + `yn-table`) without changing their behavior.

## 10. Tests

Query specs: attention classification (each kind, plus zero-state),
portfolio summary counts and YTD date range bounds (verifying future-dated
postings do not affect portfolio YTD income/expenses/net), Dashboards::RecentActivityQuery
(verifying future-dated entries excluded, previous-year entries eligible across
January 1, original entry before `through` with reversal after `through` remains
`:active`, 8-row limit newest-first, absence of per-row N+1 queries when projecting
entries, and user isolation), tenancy balance batching equals the single-tenancy
query, no cross-user leakage (two users, assert isolation), PropertySummaryQuery
YTD date range bounds (verifying future-dated postings do not enter property
YTD totals), PropertyLedgerQuery limit and through bounds (verifying December
activity remains in the 5-row preview across the January 1 year boundary).

Request specs: each property context route (200 for owner, 404 for other
user), `properties#show` no longer accepts ledger params (assert the view
renders without them and ignores them), expense create redirect target.

System specs: Overview → attention item → tenancy; property workspace tab
walk with Back/Forward and direct-URL entry (rack_test suffices).

## Suggested commits

1. `Add batch tenancy balance and overview read models`
2. `Redesign Overview around actionable state`
3. `Split property workspace into contextual routes`
4. `Simplify property overview and move ledger to activity`
5. `Add property tax tab and portfolio landing`
6. `Cover overview and property workspace journeys`

## Done when

- Overview leads with real, linked attention items;
- `properties#show` accepts no ledger/date-range filter parameters (full ledger and date filtering live exclusively on `properties/activity`);
- `properties#show` queries only bounded recent activity (`limit: 5`), batch balances, deposit balance, and YTD summary;
- Overview / Tenancies / Activity / Tax URLs all work directly;
- `properties/_financials.html.erb`, `_lease_balances.html.erb`, and
  `Dashboards::PropertySummariesQuery` are deleted;
- no per-row balance N+1 (verify in test logs);
- `bin/ci` passes.

---

# Milestone 3: Tenancy Workspace

Mockups: `tenancy.html`, `tenancy-agreement.html`,
`dialog-record-receipt.html`.

## Goal

Make the tenancy running account the primary tenancy experience.

A user opening a tenancy should immediately understand:

- who the tenancy belongs to;
- where it is;
- whether it is active;
- current rent;
- current amount due;
- which charges, receipts, reimbursements, and corrections produced that balance.

The common workflow becomes:

```text
Tenancy
→ understand balance
→ record receipt / add charge
→ see updated balance and activity
```

The implementation must preserve ordinary full-page Rails forms as direct-addressable fallbacks while enhancing short contextual actions with Turbo Frame dialogs.

---

## Normative mockups

The Milestone 3 tenancy mockups are normative for presentation.

At minimum, maintain mockups for:

- Tenancy Activity — desktop
- Tenancy Agreement — desktop
- Tenancy Activity — narrow/mobile
- Record Receipt dialog (`dialog-record-receipt.html`), which doubles as
  the normative shared short-form dialog shell

Add Charge has no separate mockup by design. It must reuse the Record
Receipt dialog shell exactly (title bar, read-only context strip,
two-column field layout, button row, validation-failure variant, focus
behavior), substituting its own fields: kind (late fee / other fee),
amount, charge date, due date, description. (Utility reimbursements
originate from the expense workflow via `ExpenseReimbursementsController`
where a source expense is required by the accounting engine, and appear in
the tenancy running account once billed.)
Later short-form dialogs (for example M5's contextual expense dialog)
reuse the same shell the same way.

The desktop and narrow/mobile tenancy mockups are the responsive
renderings of `tenancy.html` and `tenancy-agreement.html` at the
corresponding widths; there are no separate mobile files for them.

Implementations may adapt markup where required for:

- semantic HTML;
- Rails form helpers;
- Turbo Frames/Streams;
- accessibility;
- responsive behavior.

They should nevertheless preserve the mockups' intended:

- information hierarchy;
- action prominence;
- density;
- grouping;
- visual rhythm;
- responsive intent.

The mockups are **not literal HTML specifications**.

If implementation reveals that a mockup's UX is wrong, update the mockup and implementation plan in the same change rather than silently diverging.

---

## 1. Make `TenanciesController#show` the Activity screen

Keep:

```text
GET /tenancies/:id
```

as the canonical tenancy URL.

Refactor `show` so its primary concern is the running account.

Load only what the Activity view requires:

- current balance;
- current rent term;
- tenancy receivable activity;
- compact security-deposit summary;
- identifying property/unit/party context.

Use existing authoritative accounting queries:

```ruby
Accounting::TenancyBalanceQuery
Accounting::RecentTenantReceivableActivityQuery  # bounded preview (default limit: 5)
Accounting::TenantReceivableActivityQuery        # full statement / date range
Accounting::SecurityDepositBalanceQuery
```

Do not calculate balances or accounting effects in the controller or view.

The canonical Tenancy Activity screen loads bounded recent activity via
`Accounting::RecentTenantReceivableActivityQuery.call(tenancy:, limit: 5)`
for the default preview, or `Accounting::TenantReceivableActivityQuery.call(tenancy:, ...)`
when filtered by date range. Do not load unbounded activity and slice in Ruby.

---

## 2. Add an Agreement destination

Move relatively static and infrequently changed tenancy information out of the default Activity screen.

Prefer a dedicated namespaced route:

```ruby
resources :tenancies do
  scope module: :tenancies do
    resource :agreement, only: :show
  end
end
```

This produces a stable URL such as:

```text
/tenancies/:tenancy_id/agreement
```

`Tenancies::AgreementsController#show` should own:

- agreement type;
- commencement/end dates;
- participants;
- rent-term history;
- tenancy metadata;
- late-period configuration where applicable;
- unit/property references;
- agreement-oriented actions.

Do not make Activity depend on these sections merely because they belong to the same domain aggregate.

---

## 3. Preserve existing statement functionality

The existing tenancy statement/date-range workflow contains useful functionality.

Do not simply delete it.

### Preferred

Retain it as a detailed/full-history destination:

```text
View full statement
```

from Activity.

The Activity screen answers the common question; Statement handles detailed date-range/history work.

### Alternative

Redirect old statement URLs into an equivalent new Activity/history destination while preserving relevant query parameters.

Existing bookmarks and links should continue to behave sensibly.

---

## 4. Build the shared tenancy header

Create shared presentation such as:

```text
app/views/tenancies/_header.html.erb
app/views/tenancies/_tabs.html.erb
```

The header should make important state obvious.

Conceptually:

```text
Jane Smith · Unit 2
123 Main St
Active · $2,400/month · $350 due
```

Show:

- primary participant(s);
- rentable unit;
- property;
- Active / Ended state;
- current monthly rent;
- current amount due.

Do not lead with:

- internal tenancy ID;
- “Tenancy Agreement” as the page identity;
- low-frequency metadata.

These may remain secondary.

The rendered hierarchy should materially match the normative tenancy mockup.

---

## 5. Establish tenancy contextual navigation

Provide:

```text
Activity
Agreement
```

as ordinary server-addressable Rails destinations.

`Activity` is the default/canonical tenancy page.

Tabs must:

- use normal links;
- work with Turbo Drive;
- survive refresh;
- preserve Back/Forward navigation;
- have direct URLs;
- identify the active destination without relying solely on color.

Do not implement tab state in Stimulus.

---

## 6. Establish tenancy action hierarchy

For an active tenancy:

### Primary

```text
Record receipt
```

### Secondary

```text
Add charge
```

### Overflow / infrequent actions

Examples:

- Change rent
- Manage security deposit
- Edit agreement
- Manage participants
- End tenancy
- destructive operations where supported

Do not render every valid mutation as an equally prominent button.

For inactive/ended tenancies, suppress actions that are no longer valid rather than presenting actions that only fail after submission.

Server validation remains authoritative.

The prominence and placement of these actions should follow the normative Activity mockup.

---

## 7. Redesign tenancy activity

Create a reusable activity-row presentation:

```text
app/views/tenancies/_activity_row.html.erb
```

Each activity item should communicate:

- date;
- human-readable description;
- debit/charge versus credit/receipt effect;
- running balance where useful;
- correction/reversal relationship where applicable;
- source-domain link;
- accounting/audit link where useful.

Conceptual presentation:

```text
Aug 1   August rent                       +$2,400    $2,400 due
Aug 3   Receipt from Jane Smith           -$2,000      $400 due
Aug 5   Water reimbursement                  +$75      $475 due
```

Use the sign/balance semantics returned by the accounting layer.

The view may translate those semantics into user language such as:

```text
due
credit
payment
charge
```

but must not reinterpret accounting rules.

The activity screen should favor typography, alignment, and separators over wrapping every entry or subsection in an equal-weight card.

---

## 8. Keep property expenses out of tenancy activity

The tenancy running account includes events that actually affect the tenancy receivable, including:

- rent charges;
- tenant charges;
- billed reimbursements;
- receipts;
- corrections/reversals of those events.

Property expenses do **not** belong in tenancy Activity merely because they relate to the same property or unit.

A property repair appears in property financial activity.

If the tenant is billed for that repair, the resulting tenant `Charge` or reimbursement is what appears in the tenancy account.

Pin this distinction in presentation/query tests so future UX changes do not conflate property expenses with tenant debt.

---

## 9. Add a compact security-deposit summary

Create a focused summary such as:

```text
app/views/tenancies/_security_deposit_summary.html.erb
```

Show:

- amount currently held;
- simple current state;
- latest relevant deposit event if useful;
- contextual Manage action.

Do not put complete deposit history on the default Activity screen.

Detailed deposit operations/history remain behind the existing dedicated workflow.

The summary must use the authoritative deposit balance query/service rather than recomputing it in the view.

Its density and prominence should follow the normative Activity mockup.

---

# Standard Turbo Dialog Contract

Milestone 3 establishes the reusable contract for short contextual forms used here and by later UX milestones.

The contract must explicitly distinguish:

- dialog/frame presentation;
- standalone/full-page presentation.

Do not assume that a full-page Turbo-managed unsafe form automatically requests HTML.

Turbo may negotiate a Turbo Stream response for ordinary `POST`, `PATCH`, or `DELETE` submissions even outside a Turbo Frame.

Response format therefore must be selected deliberately through the form/action URL.

---

## 10. Shared dialog/full-page forms

Receipt and charge forms must remain usable in both contexts:

```ruby
form_context: :dialog
```

and:

```ruby
form_context: :standalone
```

The context may control:

- action URL/format;
- frame targeting;
- surrounding presentation;
- post-success navigation.

It must not alter:

- form fields;
- validation;
- accounting semantics;
- service calls;
- authorization.

Prefer one shared form partial per resource rather than separate modal and full-page implementations.

---

## 11. Dialog/frame form contract

A dialog-enhanced form uses the ordinary mutation URL.

Conceptually:

```ruby
tenancy_receipts_path(tenancy)
```

or the ordinary charge create path.

Because the form is Turbo-managed, successful unsafe submissions may negotiate:

```text
text/vnd.turbo-stream.html
```

The controller's `format.turbo_stream` branch is the dialog workflow.

### Dialog success

A successful receipt Turbo Stream response should update only affected UI:

```text
close_modal
tenancy_balance
tenancy_activity
flash/toast
```

For charge creation:

```text
close_modal
tenancy_balance
tenancy_activity
flash/toast
```

Add targets only when the mutation genuinely changes them.

Do not replace the entire tenancy page.

### Dialog validation failure

Return:

```text
422 Unprocessable Entity
```

and rerender/replace the form inside the modal frame.

Requirements:

- dialog remains open;
- entered values remain;
- validation errors are visible;
- no balance/activity success streams are emitted;
- focus remains useful.

---

## 12. Standalone/full-page form contract

Standalone forms remain Turbo Drive-enabled but must explicitly submit to an **HTML-format action URL**.

Conceptually:

```ruby
tenancy_receipts_path(
  tenancy,
  format: :html
)
```

Use the equivalent `.html` mutation URL for standalone charge forms.

`form_context: :standalone` is responsible for generating the HTML-format action URL.

This ensures Rails deterministically selects:

```ruby
format.html
```

rather than accidentally entering the dialog-oriented Turbo Stream branch.

Do **not** rely on:

- being outside a Turbo Frame;
- viewport size;
- absent stream targets;
- user-agent/device detection.

### Standalone success

After a successful mutation:

- use the normal HTML redirect contract;
- use `303 See Other` where appropriate after unsafe Turbo Drive submissions;
- return to tenancy Activity or another explicitly intended destination.

### Standalone validation failure

Render the normal full-page form with:

```text
422 Unprocessable Entity
```

Requirements:

- entered values remain;
- errors are visible;
- the rendered form continues to use its explicit `.html` action URL.

Prefer this over `data-turbo="false"` unless a concrete browser behavior requires native submission.

---

## 13. Controller response pattern

Receipt and charge mutation controllers should expose both contracts:

```ruby
respond_to do |format|
  format.html do
    # Standalone/direct-addressable workflow.
  end

  format.turbo_stream do
    # Dialog/frame workflow.
  end
end
```

Both branches execute the **same underlying domain mutation**.

The controller must not:

- inspect viewport width;
- inspect device type;
- infer presentation from whether DOM targets exist.

The action URL/content-negotiation contract selects the presentation response.

---

## 14. Convert Record Receipt to a Turbo Frame dialog

Reuse the existing modal infrastructure where practical.

The direct URL for a new receipt must continue to render a usable full page.

### Dialog load

When loaded into the modal frame:

- render the shared form with `form_context: :dialog`;
- use the ordinary create URL;
- successful submission returns Turbo Streams.

### Standalone load

When rendered directly:

- render the same shared form with `form_context: :standalone`;
- submit to the explicit `.html` create URL.

### Successful dialog receipt

After persistence, rerun authoritative queries and replace:

```text
tenancy_balance
tenancy_activity
```

Do not calculate the new balance by subtracting the receipt amount in JavaScript.

Close the dialog only after successful persistence.

### Failed dialog receipt

Return the form with 422 in the modal frame.

Do not close the dialog.

The resulting dialog should materially follow the normative Record Receipt mockup while preserving semantic/accessibility requirements.

---

## 15. Convert Add Charge to the same contract

Implement Add Charge using the same dialog/standalone rules.

Do not create a second modal architecture.

### Dialog

Ordinary create URL → Turbo Stream.

Update:

```text
tenancy_balance
tenancy_activity
```

and close the modal on success.

### Standalone

Explicit `.html` create URL → HTML redirect/render.

The resulting dialog should materially follow the normative shared short-form
dialog shell in `dialog-record-receipt.html`, substituting the Add Charge fields
defined above.

---

## 16. Define stable Turbo targets

Give independently changing tenancy regions persistent, unique DOM IDs:

```text
tenancy_balance
tenancy_activity
security_deposit_summary
```

Use persistent wrappers where later updates may need to target a region whose visible contents can be empty.

Do not make streams depend on targets that disappear when empty.

Do not create duplicate IDs for desktop/mobile copies of the same content.

Document these IDs in the implementation plan's stable-DOM registry if one is maintained globally.

---

## 17. Modal lifecycle behavior

Use one narrow shared Stimulus dialog controller or the existing shared controller.

Responsibilities may include:

- open;
- close;
- Escape;
- initial focus;
- focus containment;
- focus restoration;
- reacting to successful `turbo:submit-end` where necessary.

Stimulus must not:

- determine independently whether the receipt/charge succeeded;
- calculate balances;
- fabricate activity rows;
- maintain tenancy/domain state.

---

## 18. Agreement page implementation

Move low-frequency sections from the old tenancy show page into Agreement.

Prefer:

- definition lists;
- section headings;
- restrained tables;
- dividers;

over a stack of equal-weight cards.

Suggested structure:

```text
Agreement
  Dates and status
  Participants
  Current rent
  Rent history
  Other tenancy settings

Actions
  Edit agreement
  Manage participants
  Change rent
```

Keep destructive actions visually separate.

The implemented page should materially match the normative Agreement mockup at both desktop and narrow widths.

---

## 19. Query/performance pass

Before completing M3, inspect query behavior for:

- tenancy-header participant loading;
- property/unit relationships;
- current rent;
- running balance;
- activity;
- security-deposit summary.

Avoid:

- one account lookup per activity row;
- one party query per participant;
- loading unbounded journal history merely to show recent activity.

Do not introduce caching simply to hide an avoidable N+1.

---

# Testing

## 20. Query specs

Add or extend coverage for modified presentation queries.

Pin:

- current tenancy balance;
- activity ordering;
- running balance;
- reversal presentation data;
- property-expense exclusion from tenancy activity;
- bounded/recent activity behavior if introduced.

Do not duplicate existing accounting invariant specs.

---

## 21. Request specs — receipt dialog contract

Test all four response variants explicitly.

### Dialog success

Submit using the ordinary action URL as Turbo Stream.

Assert:

- response content type is Turbo Stream;
- mutation persists;
- streams include:
  - `close_modal`;
  - `tenancy_balance`;
  - `tenancy_activity`;
  - flash/toast where applicable.

### Dialog validation failure

Submit as Turbo Stream.

Assert:

- status 422;
- form is rendered into the modal frame;
- no close/balance/activity success streams are emitted.

### Standalone success

Submit to the explicit `.html` action URL.

Assert:

- mutation persists;
- response does **not** have `text/vnd.turbo-stream.html`;
- response redirects through the HTML branch;
- redirect reaches the intended tenancy page;
- redirect status is appropriate for Turbo Drive after an unsafe mutation.

### Standalone validation failure

Submit to the explicit `.html` action URL.

Assert:

- status 422;
- normal new/form page renders;
- errors are visible;
- form remains HTML-formatted.

---

## 22. Request specs — charge dialog contract

Repeat the same four-contract coverage for charges:

- dialog success;
- dialog failure;
- standalone success;
- standalone failure.

The tests should make it difficult for future controller changes to accidentally send standalone forms through the stream branch.

---

## 23. System spec — tenancy comprehension

Create representative activity and open the tenancy.

Assert that without opening another section the user can identify:

- participant;
- property/unit;
- active state;
- current rent;
- amount due;
- activity responsible for the balance.

This pins information hierarchy rather than merely checking that data exists somewhere.

---

## 24. System spec — Record Receipt dialog

1. open active tenancy;
2. record the current balance;
3. click **Record receipt**;
4. dialog opens;
5. submit a valid receipt;
6. dialog closes;
7. activity gains the receipt;
8. balance updates;
9. URL/context remains tenancy Activity;
10. refresh;
11. balance and activity remain identical.

Also test:

- validation failure keeps dialog open;
- entered values remain;
- Escape/close restores focus appropriately.

---

## 25. System spec — standalone receipt fallback

Directly visit the standalone new-receipt URL.

1. fill the form;
2. submit;
3. verify navigation follows the HTML redirect path;
4. arrive at tenancy Activity;
5. verify persisted balance/activity.

This protects the explicit `.html` form contract in a real Turbo browser.

---

## 26. System spec — charge dialog and fallback

Cover both Add Charge paths:

- contextual dialog;
- direct/full-page form.

---

## 27. System spec — Agreement navigation

1. open tenancy Activity;
2. navigate to Agreement;
3. verify URL changes;
4. verify agreement/participants/rent history appear;
5. use browser Back;
6. verify Activity returns.

---

## 28. Mockup conformance review

Before completing M3, review the implementation against every Milestone 3 normative mockup.

Verify at minimum:

- tenancy header hierarchy;
- primary/secondary action prominence;
- activity density;
- security-deposit prominence;
- Agreement grouping;
- modal dimensions/hierarchy;
- mobile composition.

Any deliberate departure must either:

1. be corrected in implementation; or
2. update the normative mockup and, where necessary, the PRD in the same change.

Do not let implementation and mockups silently drift.

---

## 29. Mobile pass

At approximately 375 px verify:

- tenancy header remains legible;
- current balance remains obvious;
- primary action remains discoverable;
- Activity rows do not create uncontrolled horizontal scrolling;
- action overflow works;
- receipt/charge dialogs fit the viewport;
- Agreement remains navigable;
- no action depends on hover.

The result should materially match the narrow rendering of the normative
tenancy mockups (`tenancy.html`, `tenancy-agreement.html`, and the dialog
shell) at that width.

---

## Suggested commits

1. `Center tenancy workspace on running-account activity`
2. `Move tenancy configuration into Agreement`
3. `Add tenancy header and action hierarchy`
4. `Define shared Turbo dialog and standalone form contract`
5. `Record receipts through contextual Turbo dialog`
6. `Add charges through contextual Turbo dialog`
7. `Harden tenancy responsive and accessibility behavior`
8. `Align tenancy implementation with normative mockups`
9. `Cover tenancy workspace and both form response paths`

---

## Done when

A user opening a tenancy can immediately answer:

```text
Who is this?
Where is the tenancy?
Is it active?
What is the current rent?
What is owed?
Why is that amount owed?
```

and can complete the common receipt/charge workflow without losing context.

Specifically:

- Activity is the canonical tenancy page;
- Agreement contains low-frequency configuration;
- property expenses are not presented as tenancy-running-account activity;
- running balance and activity use authoritative accounting queries;
- Record Receipt is the primary active-tenancy action;
- Add Charge is secondary;
- contextual forms use Turbo Frame/Stream responses;
- direct/full-page forms explicitly submit to `.html` action URLs;
- standalone successful forms redirect normally;
- standalone 422 forms remain usable;
- controllers never select presentation behavior from viewport/device state;
- JavaScript owns no accounting state;
- stable Turbo targets are unique and persistent;
- dialog focus/error behavior is covered;
- desktop and mobile workflows work;
- Activity, Agreement, dialogs, and mobile presentation materially conform to their normative mockups;
- any intentional mockup divergence is reflected back into the documentation in the same change;
- existing accounting/domain correctness gates remain green.

---

# Milestone 4: Inbox

Mockups: `inbox.html` (desktop master/detail; normative at lg and up
only, with the rendered caught-up variant at the bottom),
`inbox-review-mobile.html` (standalone review; the selected narrow flow,
see §7), `inbox-processing.html`, `inbox-history.html`.

## Goal

Turn imported transactions from a combined status/history page into a repetitive action workflow optimized for reviewing the next item.

The primary workflow becomes:

```text
Inbox → Review → Confirm → Next → Caught up
```

The implementation must preserve this loop on both wide and narrow screens.

---

## Normative mockups

The Milestone 4 Inbox mockups are normative for presentation.

At minimum, maintain mockups for:

- Inbox — Needs review, desktop/master-detail
- Inbox — Processing & failed
- Inbox — History
- Standalone review (`inbox-review-mobile.html`): the standalone review
  page at any width, and the SELECTED narrow needs-review flow (decision
  recorded in §7). `inbox.html` remains normative at lg and up only; its
  sub-lg stacked rendering is a responsive-HTML side effect, not a design.
- Inbox caught-up / empty state (rendered variant at the bottom of
  `inbox.html`)
- Inbox validation/error state where the layout materially differs (the
  422 variants are specified in `inbox-review-mobile.html` and the shared
  dialog shell; no separate file)

Implementations may adapt markup where required for:

- semantic HTML;
- Rails form helpers;
- Turbo Frames and Turbo Streams;
- accessibility;
- responsive behavior.

They should nevertheless preserve the mockups' intended:

- information hierarchy;
- queue density;
- list/detail proportions;
- selected-item treatment;
- action prominence;
- grouping;
- tab/count hierarchy;
- processing/failure prominence;
- caught-up state;
- responsive intent.

The mockups are **not literal HTML specifications**.

If implementation reveals that a mockup's UX is wrong, update the mockup and implementation plan in the same change rather than silently diverging.

---

## 1. Keep `/inbox` as the canonical UX entry

The underlying `ImportedTransaction` resource remains.

`/imported_transactions/:id` remains directly addressable and must support a standalone review experience.

The old `/imported_transactions` index may:

- redirect to `/inbox`; or
- render the same Inbox controller/view.

Prefer one canonical index rather than maintaining two competing queue screens.

---

## 2. Split the current index query

The current index conceptually loads:

- reviewable transactions;
- confirmed history;
- processing documents;
- failed documents.

Separate these concerns.

Introduce:

```text
ImportedTransactions::InboxQuery
ImportedTransactions::HistoryQuery
```

### `InboxQuery`

Return only data required for actionable Inbox views:

```ruby
InboxResult = Data.define(
  :reviewable_transactions,
  :review_count,
  :processing_documents,
  :failed_documents,
  :processing_count,
  :failed_count
)
```

Do not load confirmed history when rendering Needs review.

### `HistoryQuery`

Own:

- confirmed transactions;
- page;
- per-page;
- total pages/count;
- applicable filters.

Do not query the complete confirmation history on every Inbox request.

---

## 3. Inbox views

Provide three server-addressable views:

```text
Needs review
Processing & failed
History
```

Use URL query state:

```text
/inbox?view=review
/inbox?view=processing
/inbox?view=history&page=2
```

`review` is the normal default.

Do not use Stimulus-held state to remember the selected Inbox section.

The visual hierarchy and density of all three views should follow their normative mockups.

---

## 4. Needs-review list

Extract:

```text
app/views/imported_transactions/_review_list.html.erb
app/views/imported_transactions/_review_row.html.erb
```

Each row should communicate:

- transaction date;
- source description;
- amount;
- inferred party;
- inferred tenancy/property;
- proposed/current classification;
- unresolved state.

Do not render the complete editable confirmation form in every queue row.

The list should remain dense enough to scan several pending transactions at once.

The selected row should be identifiable without relying solely on color.

---

## 5. Shared review presentation

Refactor the transaction review UI into shared partials usable in two contexts:

```text
app/views/imported_transactions/_review_detail.html.erb
app/views/imported_transactions/_review_form.html.erb
```

The same server-side validations and form fields must power both:

1. Inbox master/detail review;
2. standalone/full-page review.

Do not maintain separate business behavior for desktop and mobile.

The wrapper must pass an explicit presentation context:

```ruby
review_context: :inbox
```

or:

```ruby
review_context: :standalone
```

Presentation context may determine:

- form action URL/format;
- Turbo Frame targeting;
- surrounding presentation;
- post-success navigation.

It must not alter:

- form fields;
- validation;
- classification;
- confirmation semantics;
- persisted business state.

The review-detail hierarchy should materially match the normative mockups.

---

## 6. Wide-screen master/detail review

At wide widths, preserve queue context:

```text
| Needs-review list | Review detail |
```

Add:

```erb
<turbo-frame id="inbox_review">
  ...
</turbo-frame>
```

Selecting a queue row loads the selected transaction into `inbox_review`.

The queue remains visible while reviewing.

The selected row should be clearly distinguishable without relying solely on color.

The list/detail proportions, row density, and review-panel prominence should materially follow the desktop normative mockup.

Do not let the detail pane expand until the queue becomes visually incidental.

---

## 7. Narrow-screen review behavior (decided: standalone review)

DECISION (2026-08-24): below lg, queue rows navigate with `_top` to the
standalone review page (`imported_transactions#show`). The normative
narrow mockup is `inbox-review-mobile.html`, which also specifies the
standalone page at every width.

Why standalone rather than a same-frame single-column flow:

- PRD §12.4 already specifies that narrow screens navigate to a focused
  review page rendering the same server-rendered form;
- the standalone HTML-format mutation contract (below) is mandatory
  regardless, for direct URLs and JS-off use, so wiring narrow screens to
  it introduces no second lifecycle that does not already exist;
- at approximately 375 px, a stacked queue pushes the review form below
  the fold, and Turbo Stream replacements land outside the visible area,
  stranding focus;
- standalone review gives a full-screen form, browser-Back queue return,
  and a redirect-to-next loop that rack_test can cover.

Implementation:

- queue row links get their `data-turbo-frame` from a small
  `responsive_frame` Stimulus controller driven by
  `matchMedia("(min-width: 1024px)")`:

```text
wide:   data-turbo-frame="inbox_review"
narrow: data-turbo-frame="_top"
```

- the controller owns only that attribute. It must not:

  - determine confirmation state;
  - choose the next transaction;
  - maintain queue state;
  - choose the response format of mutation forms.

- with JS disabled, rows navigate `_top` at every width (the default in
  the server-rendered markup is `_top`; the controller upgrades wide
  screens to the frame). The standalone page is therefore also the
  no-JS experience.

- standalone confirm success redirects (303) to the next reviewable
  transaction's standalone page, or to `/inbox` (caught-up state) when
  none remain, per the mutation contract below.

If implementation finds this decision wrong in practice, change it by
updating `inbox-review-mobile.html` (or replacing it with
`inbox-mobile.html` for a same-frame flow), the normative-scope comment
in `inbox.html`, the `mockups/README.md` table, PRD §12.4, and this
section in the same change. Mockups, PRD, and plan must not disagree
about the narrow flow.

---

# Mutation Response Contract

Inbox/frame and standalone review must use deterministic, separate response contracts.

Do not attempt to infer presentation context from browser width inside the controller.

Do not assume that being outside a Turbo Frame causes an unsafe form submission to request HTML.

Turbo-managed `POST`, `PATCH`, and `DELETE` forms may advertise Turbo Stream responses even on a full page.

Response format must therefore be selected deliberately.

---

## 8. Inbox/frame form URLs

Inbox/frame forms use their ordinary mutation URLs.

For example:

```ruby
confirm_imported_transaction_path(transaction)
```

They remain Turbo-managed and are expected to negotiate:

```text
text/vnd.turbo-stream.html
```

for successful unsafe submissions.

The controller's `format.turbo_stream` branch is the Inbox/frame workflow.

---

## 9. Standalone form URLs

Standalone forms remain Turbo Drive-enabled but must explicitly target the **HTML format**:

```ruby
confirm_imported_transaction_path(
  transaction,
  format: :html
)
```

Use equivalent `.html` action URLs for standalone update/destroy operations where those actions otherwise expose Turbo Stream responses.

`review_context: :standalone` is responsible for generating these HTML-format action URLs.

This ensures Rails deterministically enters:

```ruby
format.html
```

rather than accidentally selecting the Inbox-only Turbo Stream branch.

Do **not** rely on:

- being outside `inbox_review`;
- viewport size;
- absent DOM targets;
- controller user-agent/device detection.

Prefer explicit `.html` URLs over `data-turbo="false"` so standalone forms retain:

- Turbo Drive navigation;
- normal redirect handling;
- server-rendered 422 validation responses;
- useful browser-history behavior.

---

## 10. Inbox/frame confirmation contract

When submitted from `inbox_review`, `confirm` responds with Turbo Streams.

On successful confirmation:

1. remove the confirmed queue row;
2. update the review count;
3. replace all three persistent global Inbox badge targets:
   - `sidebar_inbox_badge`
   - `drawer_inbox_badge`
   - `mobile_inbox_badge`
4. replace `inbox_tab_counts`;
5. replace `inbox_review` with the next reviewable transaction;
6. if no reviewable transaction remains, replace it with the caught-up state;
7. append/update the normal flash/toast target.

The server selects the next transaction **after persistence**.

JavaScript must not:

- maintain a copy of the review queue;
- decrement counts independently;
- choose the next transaction.

### Validation failure

Render the same review form back into `inbox_review` with:

```text
422 Unprocessable Entity
```

Requirements:

- entered values remain;
- validation errors remain in context;
- the queue row is not removed;
- counts and badges remain unchanged;
- focus remains useful.

The validation state should follow the normative review/error mockup where one exists.

---

## 11. Standalone/full-page confirmation contract

Standalone forms submit to their explicit `.html` action URLs.

On successful confirmation:

- if another reviewable transaction exists, redirect to that transaction's standalone review URL;
- otherwise redirect to `/inbox?view=review`.

Use an appropriate post-mutation redirect status for Turbo Drive, normally:

```text
303 See Other
```

This preserves:

```text
Review → Confirm → Next
```

without depending on Inbox DOM targets that do not exist on the standalone page.

The server selects the next transaction after persistence.

### Validation failure

Render the standalone review page with:

```text
422 Unprocessable Entity
```

Preserve:

- entered values;
- validation errors;
- review context.

The rendered form must continue to use its explicit `.html` action URL.

The standalone page should materially match its normative narrow/full-page mockup if this fallback is retained.

---

## 12. Update and destroy contracts

Apply the same context split consistently.

### Inbox/frame update

Respond with Turbo Streams as needed to:

- replace `inbox_review`;
- replace the affected queue row;
- update counts/badges if reviewability changes;
- append/update flash.

### Standalone update

Use the HTML-format action.

After success:

- redirect back to the standalone transaction page or other explicitly intended location.

On validation failure:

- render with 422.

### Inbox/frame destroy

Respond with Turbo Streams:

- remove the queue row;
- update counts/badges;
- replace `inbox_review` with the next item or caught-up state.

### Standalone destroy

Use the HTML-format action.

After success:

- redirect to the next reviewable item if one exists;
- otherwise redirect to `/inbox?view=review`.

---

## 13. Controller response pattern

Controller actions retain conventional HTML behavior and add Turbo Stream support.

Conceptually:

```ruby
respond_to do |format|
  format.html do
    # Standalone/direct-addressable workflow.
  end

  format.turbo_stream do
    # Inbox/frame workflow.
  end
end
```

The request format is selected by the form/action contract:

```text
Inbox form       → ordinary URL → Turbo Stream negotiation
Standalone form  → .html URL    → HTML response
```

Both branches execute the same underlying domain mutation.

The controller must not:

- branch on viewport width;
- inspect user-agent/device type;
- infer presentation from missing DOM targets.

---

## 14. Stable global Inbox badge targets

Milestone 1 establishes:

```text
sidebar_inbox_badge
drawer_inbox_badge
mobile_inbox_badge
```

All three wrappers remain present when the count is zero.

M4 streams must replace all three whenever reviewable count changes.

Use:

```text
shared/_inbox_badge.html.erb
shared/_mobile_inbox_badge.html.erb
```

as the canonical rendering paths.

Do not reintroduce a singular `inbox_badge` DOM ID.

---

## 15. Processing & failed

Keep transient/background work separate from the decision queue.

Rows should show:

- source document;
- current processing state;
- failure message when actionable;
- retry action where supported;
- delete/recovery action where supported.

Failures requiring intervention should be more prominent than ordinary processing.

Completed history must not visually overwhelm outstanding failures.

The resulting view should materially follow the Processing & failed normative mockup.

---

## 16. Background Turbo broadcasts

The Inbox may subscribe to a user-scoped stream:

```erb
<%= turbo_stream_from [Current.user, :inbox] %>
```

Use broadcasts only for genuinely asynchronous state transitions such as:

- processing → reviewable;
- processing → failed;
- retry state.

Prefer an explicit collaborator invoked by ingestion services/jobs:

```text
ImportedTransactions::InboxBroadcastService
```

rather than presentation-heavy model callbacks.

A broadcast may replace:

```text
source_document_<id>
inbox_tab_counts
sidebar_inbox_badge
drawer_inbox_badge
mobile_inbox_badge
```

and the relevant review-list region when new work arrives.

All targets required by a broadcast must be persistent.

The application must remain completely correct after an ordinary page refresh without having received any broadcast.

---

## 17. History

Confirmed transactions belong in a conventional paginated/filterable history view.

Use server pagination.

Filters are GET parameters.

Do not add infinite scrolling.

History should remain visually secondary to outstanding review work.

The resulting page should materially match the History normative mockup.

---

## 18. Empty and caught-up states

### No review work

Show a focused caught-up state:

```text
You're caught up.
No imported transactions need review.
```

If processing work still exists, mention that separately rather than implying that the Inbox is globally idle.

### No imported transactions at all

Provide a clear upload/import action.

### Failures exist

Do not show a purely celebratory caught-up state while failed source documents require intervention.

The empty/caught-up presentation should materially follow its normative mockup and should not consume excessive visual space.

---

## 19. Focus behavior

### Wide/frame review

After successful confirmation:

- focus moves to a sensible control in the next review item;
- if no items remain, focus moves to the caught-up heading/state.

Removing a queue row must not leave focus attached to a removed node.

### Standalone review

Normal Turbo Drive redirect navigation establishes the next page lifecycle.

The next page must contain:

- a clear heading;
- a clear primary confirmation action.

Use Stimulus only if native/Turbo behavior cannot provide a sensible focus result.

---

# Testing

## 20. Query specs

Cover:

- reviewable classification;
- processing documents;
- failed documents;
- review/processing/failure counts;
- history pagination;
- user isolation.

---

## 21. Request specs

Cover both response contracts explicitly.

### Inbox/frame confirmation

Submit as Turbo Stream and assert:

- mutation succeeds;
- confirmed-row removal stream exists;
- `inbox_review` replacement exists;
- `inbox_tab_counts` replacement exists;
- all three global badge replacements exist;
- next-item or caught-up rendering is selected server-side.

### Inbox/frame validation failure

Assert:

- status 422;
- review form is rendered into the frame;
- no row-removal/count mutation streams are emitted.

### Standalone confirmation

Submit to the explicit `.html` action URL and assert:

- request resolves through the HTML branch;
- mutation succeeds;
- response does **not** use `text/vnd.turbo-stream.html`;
- redirects to the next reviewable transaction when one exists;
- redirects to Inbox when none remain.

### Standalone validation failure

Submit to the `.html` action and assert:

- status 422;
- standalone review form renders;
- entered data and errors remain;
- action URL remains HTML-formatted.

Add equivalent contract coverage for update/destroy where those actions participate in review.

---

## 22. System spec — wide-screen repeated review

1. create three reviewable transactions;
2. open Inbox at desktop width;
3. select the first;
4. detail loads without losing the queue;
5. selected row is clearly indicated;
6. confirm;
7. row disappears;
8. badges/counts decrement;
9. next item appears automatically;
10. confirm remaining items;
11. caught-up state appears;
12. refresh;
13. persisted state is identical.

This test should exercise the actual master/detail layout rather than merely invoke endpoints.

---

## 23. System spec: narrow-screen standalone review

The narrow strategy is standalone review (§7); this spec exercises that
path and only that path:

1. open Inbox at approximately 375 px;
2. select a queue row;
3. arrive at the standalone transaction page (full-page, per
   `inbox-review-mobile.html`);
4. confirm;
5. 303 redirect to the next reviewable transaction's standalone page;
6. confirm the final item;
7. 303 redirect to Inbox;
8. see the caught-up state;
9. refresh and verify the same result.

Do not stop the test after merely proving that a narrow review page
opens. A frame-based narrow flow does not satisfy this spec.

---

## 24. System spec — Processing & failed

Exercise representative:

- processing;
- failed;
- retry/recovery where supported.

Verify failure state is discoverable and does not become hidden behind completed history.

---

## 25. System spec — History

Verify:

- confirmed items appear in History rather than Needs review;
- pagination/filter query state survives refresh;
- Back/Forward behaves naturally.

---

## 26. Background update test

Where practical:

1. open Inbox with a processing document;
2. cause transition to reviewable or failed;
3. verify page updates;
4. refresh;
5. verify identical persisted state.

Broadcast behavior is an enhancement; refresh correctness is authoritative.

---

## 27. Mockup conformance review

Before completing M4, review the implementation against every Milestone 4 normative mockup.

Verify at minimum:

### Needs review — desktop

- queue density;
- list/detail proportions;
- selected-row treatment;
- primary review action;
- queue remains visually present during detail work.

### Processing & failed

- failures are clearly distinguishable from routine processing;
- status information is readable without color alone;
- recovery actions are appropriately prominent.

### History

- completed history is visually secondary;
- filters/pagination do not dominate the page.

### Review detail

- transaction identity and amount are clear;
- classification/confirmation is the primary task;
- supporting metadata remains secondary;
- validation errors preserve the same hierarchy.

### Narrow/mobile

- selected review strategy matches the normative mobile mockup;
- the common Confirm → Next loop remains obvious;
- no horizontal overflow;
- primary action remains discoverable.

### Caught up

- clearly communicates completion;
- does not obscure processing/failure state;
- provides sensible next navigation.

Any deliberate departure must either:

1. be corrected in implementation; or
2. update the normative mockup and, where necessary, the PRD in the same change.

Do not allow mockups and implementation to silently diverge.

---

## 28. Responsive pass

At minimum test:

```text
375 px
768 px
normal desktop
wide desktop
```

Verify:

- queue rows remain scannable;
- master/detail does not collapse awkwardly;
- review controls fit;
- tab counts remain legible;
- processing/failure rows work;
- history tables have an intentional mobile strategy;
- no action depends on hover;
- no uncontrolled page-level horizontal scrolling.

---

## Suggested commits

1. `Split imported transaction inbox and history queries`
2. `Introduce Inbox queue and status views`
3. `Add shared transaction review presentation`
4. `Add wide-screen Turbo master-detail review`
5. `Define frame and standalone form response contracts`
6. `Stream confirmation results and global Inbox counts`
7. `Broadcast background import status`
8. `Harden Inbox responsive and accessibility behavior`
9. `Align Inbox implementation with normative mockups`
10. `Cover desktop and narrow Inbox workflows`

---

## Done when

The common workflow is:

```text
Inbox
→ Review
→ Confirm
→ Next
→ Caught up
```

on both wide and narrow screens.

Specifically:

- Needs review, Processing & failed, and History are separate server-addressable states;
- wide-screen review preserves queue context;
- narrow-screen review uses the standalone path: rows navigate `_top` to
  the standalone page, confirmation redirects to the next reviewable item
  or to the caught-up Inbox (§7, §23);
- Inbox/frame mutation forms negotiate Turbo Stream responses;
- standalone mutation forms explicitly request HTML while remaining Turbo Drive-enabled;
- standalone successful mutations redirect to the next review item or Inbox;
- standalone 422 responses remain usable;
- controller behavior never depends on viewport width;
- the server selects the next reviewable transaction;
- all three global Inbox badge targets stay synchronized;
- background streams are optional enhancements rather than required state;
- refresh always reconstructs correct state from the database;
- completed history no longer competes with actionable work;
- failures remain visible and actionable;
- validation, focus, response-format, empty-state, and caught-up behavior are covered;
- Needs review, Processing & failed, History, review detail, caught-up state, and narrow-screen behavior materially conform to their normative mockups;
- any intentional mockup divergence is reflected back into the mockup/PRD in the same change;
- full existing domain/accounting correctness gates remain green.

---

# Milestone 5: Money and Reports

Mockups: `money-activity.html`, `money-receipts.html`,
`money-expenses.html`, `reports.html`, `schedule-e.html`,
`property-tax.html` (status language).

# Part A: Money

## 1. Money navigation

`/money` renders the Activity tab (default). Receipts and Expenses tabs
link to the existing `/receipts` and `/expenses` indexes, restyled. One
shared header partial (`app/views/money/_header.html.erb`) renders the
title + tabs on all three controllers, with the per-tab primary action
("Record receipt" / "Record expense", none on Activity).

## 2. Cross-portfolio activity query

```text
app/queries/accounting/portfolio_activity_query.rb
```

`.call(user:, date_range:, property: nil, page:, per_page:)` → paginated
`Array[Accounting::ActivityRow]` built the same way
`PropertyLedgerQuery` does (journal entries scoped to the user, projected
through `Accounting::ActivityProjector`). Reuse the projector; do not
reinterpret accounting. Every row keeps its journal-entry audit link and
source-record link. Filters (property, year) are GET params.

## 3. Normalize Receipts and Expenses indexes

Columns per the mockups. Both indexes gain pagination (defect 11) using
the same hand-rolled pattern as `HistoryQuery` or a small shared
`Paginatable` helper extracted from it (either is fine; do not add a gem).
Voided rows: strikethrough + neutral status + link to correction, exactly
like tenancy activity rows. Import indicator when
`imported_transaction`/`source import` present. Remove accounting IDs
from default display.

## 4. Contextual creation

Reinstate dialogs now that the M3 contract exists:

- property workspace header "Record expense" becomes a dialog trigger
  (`new_property_expense_path` + `turbo_frame_request?` wrapper); success
  streams `close_modal` + toast + replace of the property page's recent-
  activity/summary regions when on the property (give those regions
  stable IDs `property_summary`, `property_recent_activity`), falling back
  to redirect for full-page use;
- Money-tab "Record receipt"/"Record expense" go to the full-page forms
  (tenancy/property chosen in-form); no dialog needed there.

# Part B: Reports

## 5. Schedule E status query

```text
app/queries/reports/schedule_e_statuses_query.rb
```

`.call(user:, tax_year:)` → per property:

```ruby
ScheduleEStatus = Data.define(
  :property, :state, :unresolved_review_count, :net_income_cents
)
# state: :needs_profile | :needs_review | :ready
```

Derivation runs `TaxReporting::ScheduleEQuery.call(property:, tax_year:)`
per property and maps: `status == :tax_profile_required` → needs_profile;
`has_unresolved_reviews?` → needs_review; else ready. This is N full
Schedule E computations for N properties, once per Reports page view:
acceptable at current portfolio sizes. If it measurably is not, optimize
later with a query sharing `ScheduleEQuery`'s predicates and spec'd
against it. Correctness first.

## 6. Reports landing

`ReportsController#show` per `reports.html`: year GET param parsed via
`TaxReporting::TaxYear.parse(params[:year], default: previous_year) || TaxReporting::TaxYear.new(previous_year)`
(ensuring invalid non-blank inputs such as `'abc'` fall back cleanly to
`previous_year`), status rows with the shared row partial. Extract that row/status partial
(`app/views/reports/_property_status.html.erb`) and reuse it in
`Properties::TaxesController#show` so "Needs profile / Needs review /
Ready" have exactly one definition.

## 7. Schedule E page redesign

`properties#schedule_e` becomes a full page (defect 6): delete the
`<turbo-frame id="modal-frame">` wrapper from
`properties/schedule_e.html.erb` and rebuild per `schedule-e.html`:

- header: property, year, profile summary, readiness status line
  (`#schedule_e_readiness`), Edit tax profile secondary, Download PDF
  primary (disabled + warn alert naming the blocker when not ready);
- `#schedule_e_review`: unresolved items first with inline resolution
  forms posting to the existing
  `property_tax_review_resolutions_path`; resolved items quiet with Undo
  (DELETE). The category select shows only for the map-to-category
  treatment (reuse the `tax_profile_form` toggle pattern in a small
  controller or extend that controller);
- `#schedule_e_projection`: lines from
  `TaxReporting::ScheduleEFormDefinition.for(year)`, values from the
  result; drilldowns behind native `<details>`;
- `#schedule_e_export`: the button block.

Accounting semantics unchanged; the controller keeps using
`TaxReporting::ScheduleEQuery` and `ScheduleEGenerator` (whose three
errors continue to map to redirect-with-alert, now rarely reachable since
the button is gated).

## 8. Turbo-enable review resolutions

`PropertyTaxReviewResolutionsController` create/destroy add
`format.turbo_stream`: re-run `ScheduleEQuery`, then replace
`schedule_e_review`, `schedule_e_projection`, `schedule_e_readiness`,
`schedule_e_export`. No totals computed in the controller. HTML fallback
keeps redirecting to `schedule_e_property_path` (with `return_to_year`).
Validation errors render into `schedule_e_review` with 422.

## 9. Year selectors

Reports and property Tax year selects are GET forms auto-submitted by a
tiny shared `autosubmit` Stimulus controller (`requestSubmit` on change).
URLs keep the year.

## 10. Tests

Query specs: portfolio activity (filtering, pagination, reversal rows,
cross-user isolation); ScheduleEStatuses across the four representative
cases (no profile / ready / unresolved / reversed events) asserting
agreement with `ScheduleEQuery`.

Request specs: money activity filters; receipts/expenses pagination;
reports year handling (invalid year falls back); schedule_e page renders
without frame; resolution create/destroy turbo_stream targets; PDF gate
(blocked vs ready).

System specs: Money → Expenses → expense → property Activity → journal
(rack_test); Reports → year → unresolved property → Schedule E → resolve
(`js: true`, assert projection and export state update in place) →
Download PDF enabled.

## Suggested commits

1. `Add portfolio activity query and money navigation`
2. `Normalize and paginate receipt and expense indexes`
3. `Add schedule E status query and reports landing`
4. `Rebuild schedule E as a review-first page`
5. `Stream schedule E review resolutions`
6. `Cover money and reports workflows`

## Done when

Receipts/expenses live under Money with pagination; cross-portfolio
activity is browsable and auditable; Reports shows per-property/year
status with one shared status definition; Schedule E is a full page where
review → ready → export is obvious. `bin/ci` green.

---

# Milestone 6: Polish, Accessibility, Responsive Hardening, daisyUI removal

## Goal

Treat the redesigned application as one product, remove every transitional
piece, and prove accessibility, responsiveness, and query health. No new
information architecture.

## 1. Remove transitional UI (verified inventory + sweep)

Known-deletable by now (verify zero callers first, then delete code, spec,
and sig together):

- `app/views/shared/_navbar.html.erb` (replaced M1)
- `app/javascript/controllers/hello_controller.js` (deleted M1; verify)
- `properties/_financials.html.erb`, `properties/_lease_balances.html.erb`
  (deleted M2; verify)
- `expenses/_modal_form.html.erb`, `receipts/_modal_form.html.erb`
  (folded M2/M3; verify)
- `Dashboards::PropertySummariesQuery`, `ImportedTransactions::IndexQuery`
  (replaced M2/M4; verify)
- `active_lease_for` / `active_leases_for` aliases in `PropertiesHelper`
  and any remaining `lease_balances` keys (defect 10)
- leftover `content_for :breadcrumbs` blocks and the layout support if any
  survived
- stale screenshot assets in `public/screenshots/` (replaced in §8)

Then sweep: grep views for daisyUI class names (`card`, `stats`, `badge`,
`btn-`, `table-zebra`, `alert`, `menu`, `navbar`, `join`, `breadcrumbs`,
`toast`, `dropdown`, `divider`, `link-`, `tooltip`, `modal-open`). Convert
stragglers to the Yanushi UI vocabulary. `shared/_toast` and
`shared/_flash` get rebuilt on `yn-alert` styling in this pass (keep the
`flash-messages` ID and the `type:`/`message:` locals so no stream callers
change).

When the sweep is clean, remove daisyUI: delete the `@plugin` block from
`app/assets/tailwind/application.css` and delete
`app/assets/tailwind/plugins/daisyui.mjs`. Rebuild CSS and click through
every screen (the seeds provide data: `db:seed:replant` is already in CI).

## 2. Stimulus audit

Expected final set: `modal`, `turbo_confirm`, `toast`,
`date_range_filter`, `nested_form`, `property_units`,
`imported_transaction_form`, `tax_profile_form` (possibly generalized for
Schedule E category toggle), `navigation_drawer`, `menu`, `autosubmit`,
`responsive_frame` (required by M4's standalone narrow-review decision).
For each controller confirm: it
owns browser behavior only, no business state, no validation. Delete
anything unused. Controllers are eager-loaded, so every survivor ships on
every page; keep the list short.

## 3. Dialog and dynamic-focus pass

For the modal, confirm dialog, and navigation drawer: keyboard-operable
trigger, focus moves in on open, Escape closes, focus returns to trigger
on close, focus survives validation re-render, close control labelled,
background inert (native `showModal` provides this). For stream updates:
after receipt/charge success focus lands on the trigger, not in removed
DOM; after Inbox confirm focus moves to the loaded next-item form; after
Schedule E resolution focus stays within the review section and the
readiness change is announced (add `aria-live="polite"` to
`#schedule_e_readiness` and the Inbox count regions; verify toasts have
`role="alert"`/`role="status"` as appropriate).

## 4. Keyboard and semantics audit

Walk sidebar/drawer, tabs, overflow menus, dialogs, Inbox master/detail,
forms, Schedule E review, pagination, journal links with keyboard only.
Checks: one `h1` per page; hierarchical headings; every table has `th`
headers (`scope="col"`); every control has a label; icons are
`aria-hidden` or named; status readable without color (the `.yn-status`
word satisfies this; verify no color-only survivors); errors associated
via `aria-describedby`. Nothing may require hover.

## 5. Responsive pass

375px / 768px / 1280px / wide, for each primary workflow: no page-level
horizontal overflow; header actions wrap per the page-header pattern;
tables follow their declared strategy (comparative tables scroll inside
`overflow-x-auto`; row-oriented lists stack, per the mockup comments);
dialogs fit the viewport (`max-height` handles this); drawer navigation
covers everything the sidebar does.

## 6. Empty, loading, error states

Verify every redesigned page with zero records against its mockup-comment
spec. Loading: frame loads that are perceptibly slow get a minimal inline
"Loading…" placeholder inside the frame (Turbo shows frame busy state via
`[aria-busy]`; a small CSS rule dimming busy frames is enough); form
submit buttons rely on Turbo's automatic disable; no skeleton screens.
Errors: exercise 422 validation in both dialog and page variants, stale
Inbox item (confirm an already-confirmed record → toast error), retry
of a non-failed document, blocked PDF export, and unauthorized/not-found
(existing behavior; verify it renders inside the new shell).

## 7. Query and pagination audit

With `log_level = :debug` in development, walk: Overview, Portfolio,
property Overview/Tenancies/Activity, tenancy show, Inbox review view,
Money Activity/Receipts/Expenses, Reports, Schedule E. Look for: per-row
balance or party/unit lookups, unbounded ledger loads, Inbox review view
touching confirmed history, repeated account lookups, per-property
ScheduleEQuery outside Reports/Tax pages. Fix with eager loading or the
batch queries from M2. Confirm every potentially unbounded collection is
paginated or explicitly limited (property activity, tenancy statement,
money activity, receipts, expenses, inbox history, account activity). Do
not paper over query shape with caching.

## 8. Documentation refresh

Retake `public/screenshots/` images for Overview, Property, Tenancy,
Inbox, Schedule E/Reports at desktop width. Update `README.md` workflow
sections to describe the five-area navigation. Keep
`documentation/ux-refresh/` as the record of the design; correct any
statement the implementation diverged from.

## 9. Full system-flow coverage

Final end-to-end specs (some exist from earlier milestones; complete the
set): daily attention (Overview → item → action), tenancy receipt
(`js: true`), Inbox loop (`js: true`), tax flow (`js: true`), plus one
narrow-viewport run of the Inbox and tenancy flows. Then the full gate:

```bash
bin/ci
bundle exec rbs validate
```

Coverage thresholds stay at 95/90; do not lower them to ship.

## Suggested commits

1. `Remove superseded UI and daisyUI`
2. `Harden dialog and dynamic focus behavior`
3. `Finish responsive and table behavior`
4. `Normalize empty loading and error states`
5. `Eliminate UX query regressions`
6. `Refresh screenshots and documentation`
7. `Complete end-to-end UX coverage`

## Done when

Five areas feel like one application; zero daisyUI references and the
plugin file is gone; keyboard-complete; mobile-complete at 375px; no
unbounded lists or obvious N+1s; docs and screenshots current; `bin/ci`
and `rbs validate` green.

---

# Appendix A: UI vocabulary reference

- Canonical CSS: `documentation/ux-refresh/mockups/yanushi-ui.css`
  (copied into `app/assets/tailwind/application.css` in M1; from then on
  the app copy is the live one, and changes must be reflected back into
  the mockup file and `styleguide.html`).
- Canonical markup patterns: `documentation/ux-refresh/mockups/styleguide.html`.
- Shared partial interfaces: Milestone 1 §5.
- Formatting helpers: Milestone 1 §5 (`format_money_cents`,
  `signed_money_cents`, `balance_phrase_cents`).
- Icons: inline 16px SVG (`viewBox="0 0 16 16"`, `fill="currentColor"`,
  `aria-hidden="true"`), sourced from `app-shell.html`. No icon font, no
  icon gem.

# Appendix B: stable DOM ID registry

IDs that Turbo Streams target. Rename only with a repo-wide grep of both
Ruby and ERB.

| ID | Page | Written by |
|---|---|---|
| `flash-messages` | layout | many controllers (toast append) |
| `modal-container`, `modal`, `modal-title`, `modal-frame` | layout | modal_controller, `close_modal` action, dialog flows |
| `sidebar_inbox_badge` | desktop sidebar nav | Inbox confirm stream, broadcast service |
| `drawer_inbox_badge` | mobile drawer nav | Inbox confirm stream, broadcast service |
| `mobile_inbox_badge` | mobile topbar | Inbox confirm stream, broadcast service |
| `inbox_tab_counts` | Inbox | confirm stream |
| `inbox_review` | Inbox | row selection frame, confirm stream |
| `imported_transaction_<id>` | Inbox review list | confirm/destroy remove |
| `source_document_<id>` | Inbox processing view | broadcast service |
| `tenancy_balance` | tenancy show | receipt/charge streams |
| `tenancy_activity` | tenancy show | receipt/charge streams |
| `security_deposit_summary` | tenancy show | deposit flows (if streamed) |
| `property_summary` | property overview | expense dialog stream (M5) |
| `property_recent_activity` | property overview | expense dialog stream (M5) |
| `schedule_e_review` | Schedule E | resolution streams |
| `schedule_e_projection` | Schedule E | resolution streams |
| `schedule_e_readiness` | Schedule E | resolution streams |
| `schedule_e_export` | Schedule E | resolution streams |

# Appendix C: per-milestone checklist

Before opening each milestone PR:

1. `bin/ci` passes locally.
2. `bin/rails rbs_rails:all` was run if routes or schema changed;
   `bundle exec rbs validate` passes.
3. Every new Ruby file has a sig under `sig/app/` and specs meeting the
   coverage gate.
4. New/changed screens match their mockup (side-by-side check).
5. Superseded code introduced obsolete BY this milestone is deleted in it,
   not deferred (M6 handles only what genuinely spans milestones).
6. No new daisyUI class usage; no client-side business state; no
   accounting logic outside existing queries/services.

# Recommended branch stack

```text
ux_refresh_milestone_1
    ↓
ux_refresh_milestone_2
    ↓
ux_refresh_milestone_3
    ↓
ux_refresh_milestone_4
    ↓
ux_refresh_milestone_5
    ↓
ux_refresh_milestone_6
```

Branch each milestone from the accepted head of the previous one. Do not
develop milestones in parallel: later ones reuse conventions established
earlier (M3's dialog contract is the clearest example).

# Review strategy

For each milestone, review in this order:

1. information architecture / workflow correctness (against PRD + mockup)
2. Rails route and controller boundaries
3. query shape and ownership (names in §0.2, batching, bounds)
4. Turbo/Stimulus necessity (would a plain link/form do?)
5. accessibility and fallback behavior (frame off, JS off, refresh)
6. visual hierarchy (one purpose, one primary action, mockup fidelity)
7. tests and cleanup (coverage gate, sigs, deletions)

The critical review question is not "does the new screen look better?"
It is:

> **Does this screen make one important user task obvious while
> preserving Rails' server-owned, directly navigable, auditable model?**
