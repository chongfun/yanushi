import { Controller } from "@hotwired/stimulus"

// Attached to the Inbox queue list. It owns two pieces of browser behavior:
//
// 1. Which Turbo Frame the queue rows target: the master/detail frame at lg
//    and up, `_top` below that (the server renders `_top`, so no-JS works).
// 2. Keeping this tab honest when *another* session changes the queue. If a
//    broadcast removes the row that is open in the detail frame, or empties
//    the visible list while work remains, the tab reloads so the server picks
//    the canonical next item. Mutations this tab submitted itself are left to
//    the response streams, which are authoritative for the originating tab.
export default class extends Controller {
  static targets = ["link"]

  connect() {
    this.mediaQuery = window.matchMedia("(min-width: 1024px)")
    this._mediaListener = () => this.updateFrames()
    this.mediaQuery.addEventListener("change", this._mediaListener)
    this.updateFrames()

    // Transaction ids this tab has submitted a mutation for. Their rows may
    // disappear (own broadcast) before the response streams render; that is
    // not a remote change and must not trigger a reload. An id stays pending
    // only until the response's trailing `inbox_settle` stream has rendered
    // (see application.js); after that, remote changes to it reconcile again.
    this._pendingIds = new Set()
    this._submitStartListener = (event) => {
      const id = this.transactionIdFromForm(event.target)
      if (id) this._pendingIds.add(id)
    }
    document.addEventListener("turbo:submit-start", this._submitStartListener)
    this._settledListener = (event) => {
      const id = event.detail && event.detail.transactionId
      if (id) this._pendingIds.delete(String(id))
      // The response has rendered whatever comes next; put that item in the
      // URL so refresh and Back land on it.
      this.syncUrl(this.activeTransactionId)
    }
    document.addEventListener("inbox:settled", this._settledListener)

    // Clear pending id if submission failed before a response could settle it
    this._submitEndListener = (event) => {
      if (event.detail && !event.detail.success) {
        const id = this.transactionIdFromForm(event.target)
        if (id && this._pendingIds.has(id)) {
          this._pendingIds.delete(id)
          this.reconcileQueue()
        }
      }
    }
    document.addEventListener("turbo:submit-end", this._submitEndListener)

    this._fetchErrorListener = (event) => {
      const id = this.transactionIdFromForm(event.target)
      if (id && this._pendingIds.has(id)) {
        this._pendingIds.delete(id)
        this.reconcileQueue()
      }
    }
    document.addEventListener("turbo:fetch-request-error", this._fetchErrorListener)

    this._frameListener = (event) => {
      if (event.target.id === "inbox_review") this.syncSelectionWithFrame()
    }
    document.addEventListener("turbo:frame-load", this._frameListener)
    document.addEventListener("turbo:frame-render", this._frameListener)

    this.observer = new MutationObserver(() => this.reconcileQueue())
    this.observer.observe(this.element, { childList: true })
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
    document.removeEventListener("turbo:frame-load", this._frameListener)
    document.removeEventListener("turbo:frame-render", this._frameListener)
    document.removeEventListener("turbo:submit-start", this._submitStartListener)
    document.removeEventListener("turbo:submit-end", this._submitEndListener)
    document.removeEventListener("turbo:fetch-request-error", this._fetchErrorListener)
    document.removeEventListener("inbox:settled", this._settledListener)
    if (this._mediaListener && this.mediaQuery) {
      this.mediaQuery.removeEventListener("change", this._mediaListener)
    }
  }

  linkTargetConnected(link) {
    this.updateFrame(link)
  }

  updateFrame(link) {
    link.setAttribute("data-turbo-frame", this.isDesktop ? "inbox_review" : "_top")
  }

  updateFrames() {
    this.linkTargets.forEach((link) => this.updateFrame(link))
  }

  // Click feedback only; the server re-renders the list with the real
  // selection when the frame response arrives.
  select(event) {
    if (!this.isDesktop) return
    this.highlightRow(event.currentTarget)
    this.syncUrl(this.transactionIdFromRow(event.currentTarget))
  }

  // The reviewed item is real navigation state: keep it in the query string so
  // a refresh, a Back, or a shared link reopens the same item (the server
  // already honors selected_id and falls back when it is gone).
  syncUrl(id) {
    if (!this.isDesktop || !id) return
    const url = new URL(window.location.href)
    if (url.searchParams.get("selected_id") === String(id)) return
    url.searchParams.set("selected_id", id)
    window.history.replaceState({}, "", url.toString())
  }

  transactionIdFromRow(row) {
    const rowId = row && row.id
    return rowId && rowId.startsWith("imported_transaction_") ? rowId.replace("imported_transaction_", "") : null
  }

  // The frame finished loading a transaction: make sure its row is the one
  // marked selected. If the row is gone, another session removed it and the
  // server should decide what comes next.
  syncSelectionWithFrame() {
    if (!this.isDesktop) return

    const currentId = this.activeTransactionId
    if (!currentId) return

    const activeRow = this.rowFor(currentId)
    if (activeRow) {
      this.highlightRow(activeRow)
    } else if (!this._pendingIds.has(currentId)) {
      this.reloadCanonical()
    }
  }

  // Rows were added or removed. Remote removals of the open item, or of the
  // last visible item while work remains, need a reload; anything this tab
  // submitted itself is handled by the response streams.
  reconcileQueue() {
    if (!this.isDesktop) return

    const currentId = this.activeTransactionId
    if (currentId && this._pendingIds.has(currentId)) return

    if (this.rows.length === 0) {
      this.reloadCanonical()
      return
    }

    if (!currentId) return
    const activeRow = this.rowFor(currentId)
    if (activeRow) {
      if (activeRow.getAttribute("aria-current") !== "true") this.highlightRow(activeRow)
      return
    }

    this.reloadCanonical()
  }

  reloadCanonical() {
    Turbo.visit(window.location.href, { action: "replace" })
  }

  highlightRow(selectedLink) {
    this.linkTargets.forEach((link) => {
      const selected = link === selectedLink
      if (selected) {
        link.setAttribute("aria-current", "true")
      } else {
        link.removeAttribute("aria-current")
      }
      link.classList.toggle("border-stone-900", selected)
      link.classList.toggle("bg-stone-100", selected)
      link.classList.toggle("border-transparent", !selected)
      link.classList.toggle("hover:bg-stone-50", !selected)
    })
  }

  transactionIdFromForm(element) {
    if (!element) return null
    const form = element.tagName === "FORM" ? element : element.closest?.("form")
    if (!form || !form.id) return null
    if (!form.id.startsWith("review_form_") && !form.closest("#inbox_review")) return null
    return form.id.replace("review_form_", "") || null
  }

  get activeTransactionId() {
    const form = document.querySelector("#inbox_review form[id^='review_form_']")
    return form ? form.id.replace("review_form_", "") : null
  }

  get rows() {
    return Array.from(this.element.querySelectorAll("a[id^='imported_transaction_']"))
  }

  rowFor(id) {
    return this.element.querySelector(`#imported_transaction_${id}`)
  }

  get isDesktop() {
    return this.mediaQuery ? this.mediaQuery.matches : window.matchMedia("(min-width: 1024px)").matches
  }
}
