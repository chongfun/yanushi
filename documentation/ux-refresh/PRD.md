# Yanushi UX Refresh PRD

**Status:** Proposed  
**Scope:** Full application UX refresh  
**Primary stack:** Ruby on Rails, Hotwire, Turbo, Stimulus, Tailwind CSS  
**Target:** Current `main` after completion of the double-entry accounting project

**Companion documents:**

- `documentation/ux-refresh/implementation_plan.md`: milestone-by-milestone
  execution plan, grounded in the verified current codebase.
- `documentation/ux-refresh/mockups/`: normative HTML mockups for every
  primary screen, plus `yanushi-ui.css` (the design tokens and component
  classes) and `styleguide.html` (the shared UI vocabulary). Where this PRD
  describes a screen, the mockup shows it; markup and class recipes in the
  mockups are the reference implementation.

## 1. Summary

Yanushi's domain and accounting architecture have become substantially stronger, but the user interface still reflects the application's earlier growth pattern: persisted domain concepts are exposed as peer navigation destinations, detail pages accumulate many equal-weight cards and tables, and workflows are organized around records rather than user intent.

This project will redesign Yanushi around a small set of user concerns:

- **Overview** — what needs attention now?
- **Portfolio** — properties, units, tenancies, and people
- **Money** — receipts, expenses, and financial activity
- **Inbox** — imported transactions requiring action
- **Reports** — Schedule E and other reporting workflows

The redesign will remain a conventional server-rendered Rails application. Turbo Drive will provide normal navigation, Turbo Frames will be used for independently navigable regions such as dialogs and master/detail interactions, Turbo Streams will update the consequences of mutations, and Stimulus will provide small amounts of browser behavior.

The project will not introduce a client-side application framework, JSON API layer for first-party UI state, or duplicated client-side business state.

The desired result is an application that feels substantially more focused while becoming more Rails-native, not less.

---

# 2. Background

Yanushi currently exposes much of its domain model directly in the primary navigation. Destinations such as properties, parties, tenancies, receipts/payments, expenses, imported transactions, and accounts compete at roughly the same level.

Individual pages exhibit the same problem.

Property pages combine inventory, occupancy, balances, statistics, and detailed financial activity. Tenancy pages combine agreement details, participants, rent history, account activity, deposits, receipts, charges, and actions. Imported transactions combine active processing, errors, review work, and historical records.

The result is structurally correct but visually and cognitively unfocused:

- too many concepts appear equally important;
- frequent workflows and infrequent configuration compete for attention;
- audit information competes with operational information;
- pages answer many questions at once instead of having a primary purpose;
- the interface reflects Active Record nouns more strongly than user tasks;
- repeated cards, badges, shadows, and boxed statistics flatten the visual hierarchy.

The completed accounting work provides an opportunity to correct this. The application's real boundaries are now much clearer: portfolio state, tenancy running accounts, property financial activity, imported-transaction confirmation, and tax reporting can each become coherent workflows.

---

# 3. Product Principles

These principles are requirements for the redesign.

## 3.1 One primary purpose per screen

Every primary screen must answer a clear user question.

Examples:

- Overview: **What needs my attention?**
- Property Overview: **What is happening at this property?**
- Tenancy Activity: **What does this tenancy owe and why?**
- Inbox: **What imported financial activity requires a decision?**
- Schedule E: **What will be reported for this property and what still needs review?**

A screen may contain supporting information, but unrelated persisted objects must not be added merely because they are associated with the current record.

## 3.2 Normally one primary action

Each page or focused workflow should normally expose one visually dominant action.

Other actions may exist as secondary buttons, inline contextual actions, or an overflow menu.

Examples:

- tenancy: **Record receipt**
- inbox item: **Confirm**
- property: contextual action based on state
- Schedule E: **Download PDF** once review is complete

Dangerous and infrequent actions should not visually compete with the common path.

## 3.3 Domain objects do not automatically earn global navigation

A resource may need an index, direct URL, search path, or audit screen without belonging in primary navigation.

Global navigation represents user concerns, not the number of Rails resources in the application.

## 3.4 Context before abstraction

Users should normally encounter a tenancy through its property, financial activity through the relevant property or tenancy, and tax reporting through the relevant property/year.

Global indexes remain useful for cross-portfolio work but should not replace contextual navigation.

## 3.5 Strong server ownership

The Rails server remains authoritative for:

- business state;
- validation;
- permissions;
- workflow state;
- calculated balances;
- tax classifications;
- rendering decisions.

The browser may coordinate interaction but must not become a second application state machine.

## 3.6 Auditability remains first-class

Simplifying the common UX must not hide the accounting audit trail.

Detailed journal entries, accounts, source records, reversals, and posting information must remain reachable, but they may move into secondary or advanced surfaces.

---

# 4. Goals

## 4.1 Primary goals

1. Reduce top-level navigation to a small set of user-oriented areas.
2. Turn the dashboard into an attention-oriented Overview.
3. Make properties contextual workspaces instead of large all-purpose pages.
4. Center tenancy UX around its running account and activity.
5. Turn imported transactions into an efficient Inbox workflow.
6. Normalize receipts, expenses, and property financial activity under Money.
7. Integrate Schedule E into a clear Reports workflow.
8. Establish a reusable visual and interaction vocabulary for future Rails work.
9. Use Turbo and Stimulus deliberately where they improve workflows.
10. Preserve accounting correctness, auditability, and direct-addressable Rails pages.
11. Provide strong desktop, mobile, keyboard, loading, empty, error, and validation states.

## 4.2 Secondary goals

- Reduce repeated view markup.
- Remove daisyUI as the visible design language (full removal in Milestone 6).
- Make hierarchy understandable without relying on color.
- Make frequent actions require fewer context switches.
- Improve the quality of future UX additions by establishing explicit conventions.

---

# 5. Non-Goals

This project will not:

- replace Rails views with React, Vue, Svelte, or another SPA framework;
- introduce a first-party JSON API for UI rendering;
- adopt client-side stores or duplicate domain state in JavaScript;
- redesign the accounting model;
- change debit/credit or Schedule E semantics;
- redesign ingestion classification rules;
- add arbitrary dashboard customization;
- add a configurable chart of accounts;
- introduce an external component framework merely to complete the redesign;
- add ViewComponent, Phlex, or another rendering abstraction unless repeated Rails partial/helper patterns demonstrate a concrete need;
- make every interaction happen in a modal;
- make every section a Turbo Frame;
- perform a brand/marketing redesign unrelated to application usability.

---

# 6. Information Architecture

## 6.1 Primary navigation

Replace the current resource-oriented navigation with:

1. **Overview**
2. **Portfolio**
3. **Money**
4. **Inbox**
5. **Reports**

The currently selected area must be visibly identifiable without relying solely on color.

### Secondary/advanced navigation

The following remain accessible but do not belong in primary navigation:

- Accounts
- Journal entries / accounting audit views
- other diagnostic or low-frequency accounting surfaces

These should live beneath an **Accounting**, **Advanced**, or equivalent secondary destination.

## 6.2 Desktop shell

Use a persistent sidebar on normal desktop widths.

The sidebar should contain:

- product identity;
- primary navigation;
- Inbox attention count when nonzero;
- secondary/advanced navigation;
- user identity and sign out. (The current UI has no sign-out affordance
  anywhere; the shell must add one. `SessionsController#destroy` already
  exists.)

The content area owns page-level navigation and actions.

## 6.3 Mobile shell

On mobile:

- sidebar becomes a drawer or equivalent compact navigation;
- the current page title remains clearly visible in the page header without opening navigation;
- primary actions remain reachable without opening navigation;
- no page may require desktop-only hover behavior.

---

# 7. Shared Page Structure

Primary pages should use a consistent structure.

## 7.1 Page header

A page header can contain:

- breadcrumb or context label when useful;
- title;
- compact identifying metadata/status;
- one primary action;
- optional secondary actions or overflow menu;
- contextual navigation underneath where required.

Do not build a different header convention for every resource.

## 7.2 Contextual navigation

Tabs represent server-addressable destinations.

Examples:

### Property

- Overview
- Tenancies
- Activity
- Tax

### Tenancy

- Activity
- Agreement

Tabs should normally be regular Rails links enhanced by Turbo Drive. They must not depend on Stimulus-held client state.

A tab should have a stable URL so that:

- refresh preserves location;
- back/forward navigation works naturally;
- links can be shared/bookmarked;
- system tests can address each screen directly.

---

# 8. Overview

## 8.1 Purpose

Answer:

> What requires my attention and what is happening across the portfolio?

The Overview is not primarily a property directory.

## 8.2 Required sections

### Attention

Show actionable exceptions first.

Potential items include:

- imported transactions requiring review;
- failed imports requiring intervention;
- tenancies with meaningful outstanding balances;
- unresolved Schedule E tax-review items when relevant;
- other future exception states.

Each item should state:

- what happened;
- why attention is required;
- relevant property/tenancy context;
- direct action/navigation.

Do not show zero-count categories as prominent empty warning boxes.

### Portfolio summary

Provide compact portfolio-level information, for example:

- properties;
- occupied/vacant units;
- outstanding tenancy balance;
- current-period receipts/expenses where useful.

Limit metrics to values with a clear operational purpose.

### Properties

Show properties compactly rather than as oversized metric cards.

A property item should prioritize:

- property name/address;
- occupancy;
- relevant current financial/status signal;
- direct navigation.

### Recent activity

Show a concise chronological view of meaningful recent events.

Do not reproduce the complete accounting ledger on the dashboard.

## 8.3 Real-time enhancement

Where background ingestion changes actionable state, Turbo Streams may update:

- Inbox count;
- attention queue;
- processing/failure status.

The page must remain correct after ordinary refresh without relying on previously received streams.

---

# 9. Portfolio

## 9.1 Portfolio landing

Portfolio provides access to:

- Properties
- Tenancies
- Parties

Properties are the default perspective.

Tenancy and Party global indexes remain available for cross-portfolio lookup but do not need independent global-navigation entries.

## 9.2 Property workspace

### Property header

Show:

- property identity;
- address;
- occupancy summary;
- a small number of high-value financial/status signals;
- contextual actions.

### Property Overview

Show:

- rentable units;
- current occupants/current tenancies;
- vacancy state;
- concise current financial summary;
- noteworthy balances;
- recent property activity;
- relevant primary action.

Avoid showing the complete ledger here.

### Property Tenancies

Show:

- current tenancies first;
- unit;
- participants;
- rent;
- balance/status;
- start/end status;
- historical tenancies separately or behind a clear filter.

### Property Activity

Show financial activity associated with the property.

Requirements:

- chronological;
- filterable where useful;
- source/audit links available;
- accounting detail available on demand;
- property expenses belong here;
- tenancy-derived activity can link to the tenancy.

This is the natural place for a detailed property ledger.

### Property Tax

Show property tax configuration and Schedule E reporting for the selected year.

Provide:

- year selection;
- tax profile/status;
- review-required count;
- link into Schedule E workflow;
- generated/export state where appropriate.

---

# 10. Tenancy Workspace

## 10.1 Purpose

The default tenancy screen answers:

> What does this tenancy owe, and what activity produced that balance?

This should become one of the strongest workflows in the application.

## 10.2 Tenancy header

Show immediately:

- primary party/parties;
- rentable unit;
- property;
- active/inactive state;
- current rent;
- current balance.

Example conceptual hierarchy:

**Jane Smith · Unit 2**  
123 Main St · Active · $2,400/month · **$350 due**

## 10.3 Primary actions

For an active tenancy:

- **Record receipt** — primary;
- Add charge — secondary;
- overflow actions for infrequent tasks.

Overflow may include:

- change rent;
- manage security deposit;
- edit agreement;
- manage participants;
- end tenancy;
- other infrequent configuration.

Do not display every possible mutation as an equally prominent button.

## 10.4 Activity tab

Activity is the default.

Show:

- current running balance prominently;
- chronological tenancy account activity;
- charges;
- receipts;
- billed reimbursements;
- reversals/corrections in an understandable form.

Property expenses are **not** tenancy-running-account activity unless represented by a tenant charge/reimbursement.

### Activity item requirements

Each row should make clear:

- date;
- user-readable description;
- debit/charge vs credit/receipt effect;
- running balance where useful;
- source record;
- reversal/correction relationship.

Detailed journal/posting information should be reachable but secondary.

## 10.5 Security deposit

Show a compact deposit summary in the tenancy context:

- amount held/current state;
- relevant deposit activity;
- primary management action when appropriate.

Avoid turning the deposit into another large always-expanded section unless its history is the active task.

## 10.6 Agreement tab

Move relatively infrequent tenancy configuration here:

- agreement dates;
- participants;
- rent-term history;
- tenancy metadata;
- unit/property references;
- agreement modification actions.

The Activity screen should not be forced to display this material merely because it belongs to the same model.

---

# 11. Money

## 11.1 Purpose

Provide cross-portfolio access to monetary activity without making every financial record type a global navigation item.

## 11.2 Sections

Money is one page-level tab set with three destinations, each a direct URL:

- **Activity** (`/money`, the default): cross-portfolio financial timeline
- **Receipts** (`/receipts`, the existing index renormalized)
- **Expenses** (`/expenses`, the existing index renormalized)

Until the Activity query ships (Milestone 5), Money is a simple landing
that links to Receipts and Expenses; it must not show a disabled
placeholder tab.

## 11.3 Receipts

Support:

- recent receipts;
- property/tenancy context;
- payer;
- amount/date;
- reversal status;
- source/import relationship;
- contextual recording flow.

## 11.4 Expenses

Support:

- property;
- optional rentable unit;
- category/account meaning;
- amount/date;
- source/import relationship;
- reversal status;
- contextual creation.

Expenses should clearly read as property financial activity rather than tenancy balance activity.

## 11.5 Financial Activity

Provide a useful cross-portfolio financial timeline/audit view.

Do not simply expose raw postings as the default user experience. Human-readable event descriptions should lead; journal/posting detail is available for audit.

---

# 12. Inbox

## 12.1 Purpose

Imported transactions become an action-oriented Inbox.

Default question:

> Which imported financial transactions still need a decision?

## 12.2 Primary views

Inbox should provide:

1. **Needs review**
2. **Processing / failed**
3. **History**

Needs review is the default whenever outstanding items exist.

Counts should be shown when useful.

## 12.3 Needs-review list

Rows should communicate:

- transaction date;
- amount;
- source description;
- inferred payer/property/tenancy if available;
- confidence/context useful for confirmation;
- current classification state.

Selecting an item should open a focused review experience without losing the queue context.

## 12.4 Review interaction

Two review contexts exist, both rendering the same server-rendered form,
and both using normal Rails validation:

- Wide screens: the list stays visible and the selected item loads into a
  Turbo Frame. Successful confirmation from the frame returns Turbo
  Stream updates that remove the queue item, update the Inbox counts, and
  load the next review item (or the caught-up state).
- Narrow screens and standalone visits: the row navigates to a focused
  review page. Successful confirmation uses the normal HTML mutation path
  and redirects to the next reviewable item, or back to Inbox when caught
  up.

A successful confirmation may:

1. remove the item from Needs review;
2. decrement the Inbox count;
3. update relevant attention counts;
4. refresh affected summary information;
5. load the next review item when appropriate.

The server remains authoritative about which item comes next.

## 12.5 Processing / failed

Keep transient/background states separate from the decision queue.

Show:

- processing state;
- failure reason when actionable;
- retry/recovery action where supported.

Avoid letting successful history overwhelm failures requiring attention.

## 12.6 History

Confirmed transactions belong in a conventional paginated/filterable history view.

History does not need the same visual weight as pending work.

---

# 13. Reports

## 13.1 Reports landing

Reports should provide a cross-property entry point into Schedule E work.

Show for a selected tax year:

- properties;
- tax profile status;
- unresolved review count;
- readiness/export status;
- direct link into property Schedule E.

## 13.2 Schedule E workflow

Retain current accounting/tax semantics.

Schedule E becomes a full page. (Today the 300-line worksheet renders
inside a 480px modal dialog; that ends with this redesign.)

Improve hierarchy around:

1. property/year;
2. unresolved review;
3. projected Schedule E values;
4. supporting detail;
5. export.

Unresolved items should be visually prominent before the completed form representation.

## 13.3 Export

PDF download is the primary completion action only when all required review decisions are resolved.

When blocked, explain why and direct the user to the unresolved item rather than merely disabling the button.

---

# 14. Accounting / Advanced

Accounts, journal entries, and posting-level inspection remain available.

Their purpose is:

- audit;
- diagnostics;
- accounting inspection;
- tracing business events to postings.

They should not dominate the operational workflow.

A user viewing an operational event should be able to follow an **Accounting details** link into the relevant journal entry.

A journal entry should link back to its source domain event where possible.

---

# 15. Hotwire Architecture

## 15.1 Turbo Drive

Turbo Drive is the default mechanism for normal application navigation.

Use ordinary Rails links and controllers.

Do not replace navigational pages with JavaScript state solely to avoid a server request.

## 15.2 Turbo Frames

Use Turbo Frames when a portion of the page has an independently useful navigation lifecycle.

Expected uses:

- modal/dialog forms;
- Inbox master/detail review;
- focused inline editing;
- filters or paginated regions where preserving surrounding context materially improves the workflow.

Do **not** wrap every card or section in a frame.

A frame should exist because it solves a navigation/context problem.

## 15.3 Turbo Streams

Use Turbo Streams for consequences of mutations.

Examples:

- remove a confirmed Inbox item;
- decrement an Inbox badge;
- append/update an activity row;
- update a tenancy balance;
- refresh an attention item;
- update background import status.

A Turbo Stream must not be required to establish correct state after a refresh.

## 15.4 Stimulus

Stimulus is limited to browser behavior.

Appropriate uses include:

- opening/closing dialogs;
- focus management;
- keyboard shortcuts where justified;
- disclosure/overflow menus;
- auto-submit;
- debounce;
- dependent form presentation;
- copy-to-clipboard;
- preserving reasonable scroll/focus behavior after frame changes.

Stimulus must not:

- own authoritative business state;
- calculate balances;
- implement accounting/tax decisions;
- become an API client layer;
- duplicate Rails validations;
- construct large HTML interfaces in JavaScript.

## 15.5 Background updates

Where background jobs affect visible state, Turbo Streams may be broadcast to interested pages.

The underlying database/query state remains authoritative.

---

# 16. Forms and Dialogs

## 16.1 Use dialogs for short contextual tasks

Good candidates:

- record receipt;
- add charge;
- simple expense;
- edit compact metadata;
- confirm focused Inbox action.

A dialog should not contain a large multi-step workflow merely to avoid navigating away.

## 16.2 Validation

Validation errors must render inside the same context:

- modal form remains open;
- entered values remain;
- focus moves or is announced appropriately;
- server validation messages are visible.

No separate JavaScript validation system should be required for correctness.

## 16.3 Successful mutation

After success:

- close/replace the frame;
- update affected visible state through Turbo Streams when worthwhile;
- preserve a clear success indication;
- maintain useful focus.

---

# 17. Visual System

## 17.1 Direction

The redesign should rely more on:

- typography;
- spacing;
- alignment;
- dividers;
- restrained surfaces;
- clear action hierarchy.

It should rely less on:

- a card around every section;
- decorative shadows;
- colored badges for ordinary metadata;
- boxed statistics for every number;
- multiple simultaneous primary-looking buttons.

## 17.2 Tailwind first; daisyUI is transitional

Keep Tailwind (v4, already installed via tailwindcss-rails).

The redesign's visible design language is a small first-party layer,
"Yanushi UI": Tailwind utilities for layout plus the component classes
defined in `documentation/ux-refresh/mockups/yanushi-ui.css` (buttons,
form fields, status, tabs, tables, menus, alerts, empty states, count
badges, sidebar navigation, dialog). No external component framework is
added, and no framework that ships its own JavaScript (that would compete
with Stimulus).

daisyUI's role during the refresh:

- it stays installed through Milestones 1 to 5 so pages not yet redesigned
  keep rendering;
- new and redesigned views must not use daisyUI classes;
- Milestone 6 removes the plugin and the vendored
  `plugins/daisyui.mjs` once a repo-wide sweep finds no remaining daisyUI
  class usage.

## 17.3 Yanushi UI vocabulary

The shared vocabulary is specified concretely in
`mockups/yanushi-ui.css` (styling) and `mockups/styleguide.html` (markup
patterns and usage rules), and is realized as ordinary Rails partials and
helpers:

- page header (`shared/_page_header`: eyebrow, title, meta, actions, tabs);
- tabs (`shared/_tabs`);
- status (`shared/_status`: dot + word);
- empty state (`shared/_empty_state`);
- data tables (`.yn-table` with money-column conventions);
- action hierarchy (`.yn-btn-primary` / `-secondary` / `-ghost` /
  `-danger`);
- overflow menu (`.yn-menu` over native `details`);
- dialog (existing `modal-*` infrastructure, restyled);
- alerts (`.yn-alert*`), count badges (`.yn-count`), pagination;
- money/date formatting helpers (one home for currency strings).

Do not introduce a component framework merely for theoretical consistency;
partials, helpers, and the shared stylesheet are sufficient.

## 17.4 Status color

Reserve strong color for meaningful state:

- destructive/error;
- warning/action required;
- success/complete;
- selected primary action where appropriate.

Ordinary metadata should normally use typography rather than colored pills.

---

# 18. Tables and Dense Data

Use tables where comparison across rows/columns is the actual task.

Do not convert every table into cards merely for aesthetics.

Requirements:

- meaningful headings;
- right-align numeric money columns;
- stable date/amount formatting;
- clear row actions;
- accessible row links/actions;
- mobile fallback.

On narrow screens, choose intentionally between:

- reduced columns;
- stacked row presentation;
- horizontal scroll for genuinely tabular data.

The entire page must not acquire uncontrolled horizontal scrolling.

---

# 19. Empty, Loading, Error, and Disabled States

Every redesigned workflow must explicitly handle:

## Empty

Explain:

- what is absent;
- whether that is good/normal;
- what the user can do next.

Avoid decorative empty-state art unless it materially improves understanding.

## Loading

Frame/background loading must not cause major layout jumps.

Use restrained loading indicators or placeholders where an operation is perceptibly asynchronous.

## Error

Errors should:

- remain in workflow context;
- state what failed;
- distinguish retryable system failures from validation;
- provide a next action where possible.

## Blocked action

When an action is unavailable because prerequisites are missing, explain the prerequisite.

Example:

> PDF export is unavailable because 2 tax-review items still need decisions.

This is preferable to an unexplained disabled button.

---

# 20. Accessibility

Accessibility is part of the redesign definition of done.

Requirements:

- all workflows keyboard-operable;
- visible focus;
- semantic headings;
- form controls associated with labels;
- status is not communicated through color alone;
- dialog focus is trapped appropriately while open and restored on close;
- menus use appropriate semantics/keyboard behavior;
- Turbo Frame replacement must not leave focus in a removed node;
- validation/error messages are programmatically understandable;
- touch targets are usable on mobile;
- motion is restrained and honors reduced-motion preferences where applicable;
- no information is available only through hover.

---

# 21. Responsive Requirements

Target at minimum:

- narrow mobile around 375 px;
- tablet;
- normal laptop/desktop;
- wide desktop.

Requirements:

- no uncontrolled page-level horizontal overflow;
- primary actions remain discoverable;
- sidebar collapses cleanly;
- master/detail Inbox becomes a sensible narrow-screen navigation;
- large headings/actions do not consume most of a mobile viewport;
- tables have an explicit responsive strategy;
- dialogs fit available viewport height and scroll internally where necessary.

---

# 22. URL and Navigation Requirements

The redesign must preserve Rails' strengths.

- Important states have stable URLs.
- Browser Back/Forward behaves naturally.
- Refresh does not destroy meaningful navigation state.
- Property/tenancy/report tabs are addressable directly.
- Filters should use URL parameters when they represent shareable/query state.
- Modal enhancement must not be the only way to access essential forms where a direct page remains useful.
- Existing URLs should be retained or redirected where practical.

---

# 23. Performance Requirements

The UX redesign must not compensate for cleaner pages with excessive query cost.

For each primary page:

- inspect query counts;
- eliminate obvious N+1 queries;
- paginate long collections;
- do not preload unlimited historical activity;
- do not render entire ledgers merely to show a summary;
- Turbo Frame requests should render only the intended region where practical.

Background/import updates should not trigger broad page rerenders when a small stream update is sufficient.

No hard client-side performance framework is required.

---

# 24. Testing Strategy

## 24.1 Model/domain tests

Existing accounting/domain tests remain authoritative.

UX work must not rewrite these merely to accommodate presentation changes.

## 24.2 Request tests

Cover:

- new page/action routing;
- filters;
- Turbo Frame responses where meaningful;
- Turbo Stream mutation responses;
- error states;
- redirect/fallback behavior.

## 24.3 System tests

The suite currently runs system specs through rack_test only; Selenium
headless Chrome is configured but unused, and no `js: true` spec exists.
Dialog, Turbo Frame, and Turbo Stream workflows cannot be verified by
rack_test, so this project must stand up the `js: true` path (locally and
in CI) in Milestone 1 and use it for the modal and Inbox journeys below.
Journeys that are plain navigation stay on rack_test for speed.

Add or update system coverage around the key user journeys:

### Workflow A — Overview to tenancy action

1. open Overview;
2. identify tenancy requiring attention;
3. open tenancy;
4. record receipt;
5. observe updated balance/activity.

### Workflow B — Property financial activity

1. open Portfolio;
2. open property;
3. navigate to Activity;
4. find expense/receipt;
5. reach accounting detail.

### Workflow C — Inbox confirmation

1. open Inbox;
2. select review item;
3. confirm classification;
4. item leaves queue;
5. count updates;
6. next item remains actionable.

### Workflow D — Schedule E

1. open Reports;
2. select property/year;
3. resolve review item;
4. verify readiness;
5. export becomes available.

### Workflow E — Responsive navigation

Exercise representative primary workflows at a narrow viewport.

## 24.4 Accessibility testing

Automated accessibility tooling may be added if lightweight and reliable, but it does not replace keyboard/manual review of dialogs, menus, focus, and dynamic frame updates.

---

# 25. Migration and Compatibility

This project should not require a data migration.

Domain models and accounting semantics remain unchanged unless a separate correctness issue is discovered.

Presentation-specific query objects/read models may be introduced when they:

- prevent view complexity;
- avoid duplicate query logic;
- improve page-level performance.

They must not become a second business-logic layer.

Existing resource routes may remain available even when removed from primary navigation.

---

# 26. Implementation Milestones

The redesign must land as a stack of independently reviewable changes.

## Milestone 1 — UX Foundation and Application Shell

### Scope

- introduce new primary information architecture;
- desktop sidebar;
- mobile navigation;
- shared page header;
- shared tabs;
- action hierarchy;
- status/empty-state conventions;
- introduce the Yanushi UI component layer (design tokens + component
  classes from `mockups/yanushi-ui.css`);
- user identity and sign out in the shell;
- fix the modal-frame reopen and dialog labelling defects;
- prove the `js: true` system-test path locally and in CI;
- move Accounting to secondary navigation;
- preserve existing underlying workflows.

### Done when

- primary navigation is Overview / Portfolio / Money / Inbox / Reports;
- all existing functionality remains reachable;
- mobile navigation works;
- important pages use the new header conventions;
- no major workflow behavior has yet changed;
- system tests cover shell/navigation.

---

## Milestone 2 — Overview and Portfolio

### Scope

- rebuild Dashboard as Overview;
- attention queue;
- compact portfolio summary;
- property list redesign;
- property workspace;
- Overview / Tenancies / Activity / Tax contextual navigation;
- move detailed ledger out of property Overview.

### Done when

- Overview leads with actionable state;
- property Overview is substantially simpler;
- current occupancy is immediately understandable;
- full property financial history lives in Activity;
- tax entry point lives under Tax;
- properties remain usable on mobile;
- direct tab URLs work.

---

## Milestone 3 — Tenancy Workspace

### Scope

- tenancy header redesign;
- Activity default;
- running balance emphasis;
- simplified account activity;
- primary Record Receipt action;
- secondary Add Charge;
- overflow infrequent actions;
- compact deposit summary;
- Agreement tab;
- Turbo Frame dialogs for appropriate short actions.

### Done when

A user can open a tenancy and immediately determine:

- who/where it is;
- whether it is active;
- current rent;
- current balance;
- why that balance exists.

Recording a receipt updates the visible activity/balance without requiring a manually orchestrated full-page workflow.

---

## Milestone 4 — Inbox

### Scope

- replace monolithic imported-transactions page with Inbox;
- Needs review / Processing & failed / History;
- focused review experience;
- Turbo Frame master/detail on wide screens;
- appropriate narrow-screen fallback;
- Turbo Stream confirmation;
- counts/attention updates;
- preserve full history.

### Done when

A user can repeatedly confirm imported transactions without losing queue context and without the page mixing completed history into the primary task.

---

## Milestone 5 — Money and Reports

### Scope

- normalize Receipts;
- normalize Expenses;
- add/normalize cross-portfolio Activity;
- Reports landing;
- Schedule E becomes a full, review-first page (leaving the modal);
- review-required state before export;
- align property Tax view with Reports.

### Done when

- receipts and expenses are discoverable without separate global nav clutter;
- property expenses are clearly distinct from tenancy running-account activity;
- financial activity remains auditable;
- Reports answers which properties/years require work;
- Schedule E review → ready → export is visually obvious.

---

## Milestone 6 — Polish, Accessibility, and Responsive Hardening

### Scope

- keyboard/focus pass;
- dialog/menu semantics;
- loading states;
- error states;
- empty states;
- mobile table strategies;
- responsive QA;
- query/performance audit;
- remove superseded styles/partials/controllers;
- remove daisyUI (plugin block and vendored `plugins/daisyui.mjs`) after a
  repo-wide sweep confirms no remaining usage;
- refresh README screenshots/current UI documentation.

### Done when

- all primary workflows pass at desktop and mobile widths;
- keyboard operation is complete;
- no obsolete UX implementation remains;
- no uncontrolled horizontal page overflow;
- no obvious N+1 regressions;
- documentation/screenshots match the finished product.

---

# 27. Cross-Milestone Constraints

Every milestone must:

1. remain deployable independently;
2. preserve accounting invariants;
3. preserve auditability;
4. avoid client-side business state;
5. include appropriate request/system coverage;
6. pass the existing full test/type/lint/security suite;
7. avoid unrelated domain refactoring;
8. remove superseded UI code once its replacement lands rather than maintaining two permanent presentation systems.

---

# 28. Acceptance Scenarios

The complete UX project is accepted when the following scenarios are straightforward.

## Scenario 1 — Daily review

The user opens Yanushi and can determine what needs attention without visiting every resource index.

## Scenario 2 — Tenant owes money

The user reaches the tenancy, immediately sees the amount due and its causes, records a receipt, and sees the updated running account.

## Scenario 3 — Property repair

The user records or finds a property expense and understands that it belongs to property financial activity, not the tenant balance unless separately billed.

## Scenario 4 — Imported bank activity

The user opens Inbox, reviews a transaction, confirms it, and proceeds through remaining work without repeatedly navigating back to a giant index.

## Scenario 5 — Audit

From a user-facing financial event, the user can reach the journal/accounting detail and trace the balanced postings and source.

## Scenario 6 — Tax preparation

The user opens Reports, sees which property/year has unresolved Schedule E items, resolves them, reviews the projection, and exports the PDF.

## Scenario 7 — Mobile use

The same core workflows remain usable on a narrow viewport without hidden actions, desktop-only navigation, or unreadable page structure.

---

# 29. Success Criteria

The UX refresh is complete when:

- top-level navigation has been reduced to the five user-oriented areas;
- the Dashboard has become an attention-oriented Overview;
- Property and Tenancy pages have distinct primary purposes;
- Tenancy Activity centers the running account;
- property expenses no longer visually imply tenancy-balance activity;
- imported transactions operate as an Inbox;
- Schedule E is integrated into a Reports workflow;
- accounting/audit surfaces remain available but secondary;
- frequent mutations use Turbo Frames/Streams where they materially preserve context;
- Stimulus contains behavior rather than business state;
- all meaningful pages have direct Rails URLs;
- desktop and mobile navigation are coherent;
- empty/loading/error/blocked states are intentionally designed;
- keyboard and focus behavior works across primary workflows;
- visual hierarchy no longer depends on surrounding every concept with an equal-weight card;
- daisyUI is removed and the Yanushi UI layer is the only styling system;
- current UI documentation/screenshots match the finished application;
- existing accounting, RBS/Steep, test, lint, coverage, and security gates remain green.

---

# 30. Final Architectural Rule

When adding future UI to Yanushi:

> **Start from the user's task, not the underlying Rails resource. A screen should have one primary purpose and normally one primary action. Use server-rendered Rails as the source of truth, Turbo to preserve useful context, and Stimulus only for browser behavior.**

A new model, query, or controller does not automatically justify a new top-level destination, card, tab, or JavaScript state machine.
