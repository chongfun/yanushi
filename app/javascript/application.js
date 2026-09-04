// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import { Turbo } from "@hotwired/turbo-rails"
import "controllers"
import { showConfirmDialog } from "controllers/turbo_confirm_controller"

// Delegate Turbo confirmation to custom dialog
const confirmMethod = (message, _element) => {
  return showConfirmDialog(message)
}

if (Turbo.config?.forms) {
  Turbo.config.forms.confirm = confirmMethod
}
Turbo.setConfirmMethod(confirmMethod)
document.documentElement.dataset.turboConfirmReady = "true"

// <turbo-stream action="inbox_settle" target="imported_transaction_ID">
// Sent last in every Inbox mutation response so the originating tab knows its
// own request has fully rendered. Runs in stream order, after the DOM changes
// that precede it, and announces the settled transaction to interested
// controllers (responsive_frame stops treating the id as pending).
Turbo.StreamActions.inbox_settle = function () {
  const id = (this.getAttribute("target") || "").replace("imported_transaction_", "")
  if (id) {
    document.dispatchEvent(new CustomEvent("inbox:settled", { detail: { transactionId: id } }))
  }
}

// Turbo Drive swaps the <body> without moving focus, so after clicking a tab
// or a sidebar link a keyboard user starts tabbing from the top of the
// document again. Move focus to the new page's heading instead, quietly
// (`tabindex="-1"` keeps the heading out of the tab order, `preventScroll`
// leaves Turbo's own scroll restoration alone).
//
// Only for visits the reader asked for: the first load belongs to the skip
// link and to any autofocus field, `replace` visits are the Inbox
// reconciliation reloads (they must not pull focus out from under anyone),
// `restore` is Back/Forward, and Turbo Frame or Stream renders never get here
// at all — the dialogs and the Inbox detail frame place focus themselves.
let focusHeadingAfterVisit = false
document.addEventListener("turbo:visit", (event) => {
  focusHeadingAfterVisit = event.detail?.action === "advance"
})
document.addEventListener("turbo:load", () => {
  const wanted = focusHeadingAfterVisit
  focusHeadingAfterVisit = false
  if (!wanted || document.querySelector("[autofocus]")) return

  const heading = document.querySelector("#main h1")
  if (!heading) return
  heading.setAttribute("tabindex", "-1")
  heading.focus({ preventScroll: true })
})
