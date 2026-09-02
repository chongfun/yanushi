import { Controller } from "@hotwired/stimulus"

let currentMaxRevision = -1

document.addEventListener("turbo:before-visit", () => {
  currentMaxRevision = -1
})

export default class extends Controller {
  static values = {
    revision: Number,
    reviewCount: Number,
    staleRecovery: Boolean
  }

  connect() {
    if (this.hasStaleRecoveryValue && this.staleRecoveryValue) {
      this.refreshInbox()
      return
    }

    const rev = this.hasRevisionValue ? this.revisionValue : 0

    if (currentMaxRevision < 0) {
      // First connection on this page visit: initialize baseline
      currentMaxRevision = rev
      return
    }

    if (currentMaxRevision > 0 && this.hasRevisionValue && rev < currentMaxRevision) {
      // Stale response arrived after a newer broadcast; refresh to canonical server state
      this.refreshInbox()
      return
    }

    currentMaxRevision = Math.max(currentMaxRevision, rev)
  }

  revisionValueChanged(newRevision, _oldRevision) {
    if (newRevision === undefined) return

    if (currentMaxRevision > 0 && newRevision < currentMaxRevision) {
      this.refreshInbox()
      return
    }

    currentMaxRevision = Math.max(currentMaxRevision, newRevision)
  }

  refreshInbox() {
    Turbo.visit(window.location.href, { action: "replace" })
  }
}
