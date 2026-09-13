# UX refresh mockups

Static HTML mockups for the Yanushi UX refresh. Open any file directly in a
browser (`open documentation/ux-refresh/mockups/overview.html`). Tailwind
utilities are compiled at view time by the Tailwind v4 browser CDN, so
viewing requires network access; the component classes in `yanushi-ui.css`
render regardless.

## How to use these when implementing

- **Visual hierarchy, component recipes, behavior, states, and responsive intent are normative.**
  The `.yn-*` component classes, Tailwind layout utility patterns, heading
  hierarchy, ARIA semantics, and interactive states represent the target UX.
- **HTML is not a literal ERB specification.** Implementations may adapt
  structure for semantic HTML, Rails form builders, Hotwire/Turbo mechanics,
  and accessibility best practices.
- **Stable DOM IDs are literal contracts.** IDs registered in the implementation
  plan's Appendix B registry (e.g. `sidebar_inbox_badge`, `drawer_inbox_badge`,
  `mobile_inbox_badge`, `inbox_review`, `modal-frame`) must match exactly across
  all views and Turbo Stream responses.
- **Sample data is illustrative.** Names, amounts, and counts are fake.
- **HTML comments document behavior.** Each file's header comment names
  the Rails controller/route it represents, the Turbo Stream and standalone
  HTML contracts, and the empty/error/variant states.
- **`yanushi-ui.css` is the single source for component styling.** Its contents
  are copied into `app/assets/tailwind/application.css` (after `@import "tailwindcss";`).
  If a screen needs a new atom, add it to `yanushi-ui.css` and `styleguide.html`
  first, then use it. Any deliberate UX or stable-target divergence must be
  reflected back into the mockups and documentation.
- The sidebar in per-screen mockups is abbreviated (no icons). The
  canonical sidebar (icons, stable badge wrappers, Accounting section, user row with
  sign out) is in `app-shell.html`.

## Files by milestone

| Milestone | File | Represents |
|---|---|---|
| 1 | `styleguide.html` | Shared UI vocabulary (buttons, fields, status, tabs, tables, menus, alerts, empty states, pagination, dialog) |
| 1 | `app-shell.html` | Layout, sidebar, mobile top bar + drawer, canonical page header |
| 2 | `overview.html` | Overview (`/`): attention queue, portfolio summary, properties, recent activity |
| 2 | `portfolio.html` | Portfolio landing (`/portfolio`) |
| 2 | `property-overview.html` | Property workspace, Overview tab |
| 2 | `property-tenancies.html` | Property workspace, Tenancies tab |
| 2 | `property-activity.html` | Property workspace, Activity tab (the property ledger) |
| 2/5 | `property-tax.html` | Property workspace, Tax tab |
| 3 | `tenancy.html` | Tenancy workspace, Activity tab (canonical tenancy page) |
| 3 | `tenancy-agreement.html` | Tenancy workspace, Agreement tab |
| 3 | `dialog-record-receipt.html` | Record receipt dialog over the tenancy page; also the normative shared short-form dialog shell (Add Charge and later short-form dialogs reuse it with their own fields, with no separate mockup) |
| 4 | `inbox.html` | Inbox, Needs review: desktop master/detail, normative at lg and up only; includes the rendered caught-up variant. The sub-lg stacked rendering is not normative |
| 4 | `inbox-review-mobile.html` | Standalone review page (`imported_transactions#show`) at any width, and the selected narrow needs-review flow (plan M4 §7) |
| 4 | `inbox-processing.html` | Inbox, Processing & failed |
| 4 | `inbox-history.html` | Inbox, History (paginated) |
| 5 | `money-activity.html` | Money, Activity tab (cross-portfolio timeline) |
| 5 | `money-receipts.html` | Money, Receipts tab |
| 5 | `money-expenses.html` | Money, Expenses tab |
| 5 | `reports.html` | Reports landing (Schedule E status by property/year) |
| 5 | `schedule-e.html` | Schedule E workflow page (full page, review-first) |

## Design rules the mockups encode

1. One `h1`, one primary action (`.yn-btn-primary`) per screen.
2. Sections are heading + hairline divider; `.yn-surface` boxes are
   reserved for genuinely separate regions (attention queue, master/detail
   panes, status row groups).
3. Status is a dot plus a word (`.yn-status`), not a colored pill, and
   color is not the only carrier of meaning. Ordinary metadata is plain
   text with `·` separators.
4. Money is always `text-right tabular-nums` with cents; receipts/credits
   carry a real minus sign (−); balances spell out "due" / "credit" /
   "Settled".
5. Voided/corrected records stay visible: strikethrough, neutral status,
   link to the correction.
6. Tabs are server-rendered links with `aria-current="page"`; state lives
   in the URL.
7. Every list has a designed empty state (in comments where not shown).
8. The accent palette is fixed: stone neutrals, indigo links/focus, amber
   for needs-attention, red for failed/destructive, green for
   active/ready. daisyUI classes do not appear in any mockup.
