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
