import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["link"]

  connect() {
    this.mediaQuery = window.matchMedia("(min-width: 1024px)")
    this._mediaListener = () => this.updateFrames()
    this.mediaQuery.addEventListener("change", this._mediaListener)
    window.addEventListener("resize", this._mediaListener)
    this.updateFrames()

    this._localSubmitting = false
    this._submitStartListener = (event) => {
      const form = event.target
      if (form && (form.id?.startsWith("review_form_") || form.closest("#inbox_review"))) {
        this._localSubmitting = true
      }
    }
    this._submitEndListener = () => {
      this._localSubmitting = false
    }
    document.addEventListener("turbo:submit-start", this._submitStartListener)
    document.addEventListener("turbo:submit-end", this._submitEndListener)

    this._frameListener = (event) => {
      if (event.target.id === "inbox_review") {
        this.syncSelectionWithFrame()
      }
    }
    document.addEventListener("turbo:frame-load", this._frameListener)
    document.addEventListener("turbo:frame-render", this._frameListener)

    this.observer = new MutationObserver(() => this.reconcileQueue())
    this.observer.observe(this.element, { childList: true })
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
    }
    if (this._frameListener) {
      document.removeEventListener("turbo:frame-load", this._frameListener)
      document.removeEventListener("turbo:frame-render", this._frameListener)
    }
    if (this._submitStartListener) {
      document.removeEventListener("turbo:submit-start", this._submitStartListener)
      document.removeEventListener("turbo:submit-end", this._submitEndListener)
    }
    if (this._mediaListener) {
      if (this.mediaQuery) {
        this.mediaQuery.removeEventListener("change", this._mediaListener)
      }
      window.removeEventListener("resize", this._mediaListener)
    }
  }

  syncSelectionWithFrame() {
    const isDesktop = window.matchMedia("(min-width: 1024px)").matches
    if (!isDesktop) return

    const currentForm = document.querySelector("#inbox_review form[id^='review_form_']")
    const currentTxnId = currentForm?.id?.replace("review_form_", "")
    if (!currentTxnId) return

    const activeRow = this.element.querySelector(`#imported_transaction_${currentTxnId}`)
    if (activeRow) {
      this.highlightRow(activeRow)
    } else {
      Turbo.visit(window.location.href, { action: "replace" })
    }
  }

  reconcileQueue() {
    const isDesktop = window.matchMedia("(min-width: 1024px)").matches
    if (!isDesktop) return
    if (this._localSubmitting) return

    const remainingRows = Array.from(this.element.querySelectorAll("a[id^='imported_transaction_']"))
    if (remainingRows.length === 0) {
      // Refresh if all rows were removed
      Turbo.visit(window.location.href, { action: "replace" })
      return
    }

    // Check if active transaction is still present
    const currentForm = document.querySelector("#inbox_review form[id^='review_form_']")
    const currentTxnId = currentForm?.id?.replace("review_form_", "")
    const currentlyActiveRow = currentTxnId ? this.element.querySelector(`#imported_transaction_${currentTxnId}`) : null

    if (currentlyActiveRow) {
      // Restore selection styling if reset by remote replacement
      if (currentlyActiveRow.getAttribute("aria-current") !== "true") {
        this.highlightRow(currentlyActiveRow)
      }
      return
    }

    // Active transaction was removed remotely; refresh view
    Turbo.visit(window.location.href, { action: "replace" })
  }

  linkTargetConnected(link) {
    this.updateFrame(link)
  }

  updateFrame(link) {
    const isDesktop = window.matchMedia("(min-width: 1024px)").matches
    link.setAttribute("data-turbo-frame", isDesktop ? "inbox_review" : "_top")
  }

  updateFrames() {
    const links = this.hasLinkTarget ? this.linkTargets : this.element.querySelectorAll("a[data-responsive-frame-target='link']")
    links.forEach((link) => this.updateFrame(link))
  }

  highlightRow(selectedLink) {
    const links = this.hasLinkTarget ? this.linkTargets : this.element.querySelectorAll("a[data-responsive-frame-target='link']")
    links.forEach((link) => {
      if (link === selectedLink) {
        link.setAttribute("aria-current", "true")
        link.classList.add("border-stone-900")
        link.classList.add("bg-stone-100")
        link.classList.remove("border-transparent")
        link.classList.remove("hover:bg-stone-50")
      } else {
        link.removeAttribute("aria-current")
        link.classList.remove("border-stone-900")
        link.classList.remove("bg-stone-100")
        link.classList.add("border-transparent")
        link.classList.add("hover:bg-stone-50")
      }
    })
  }

  select(event) {
    const isDesktop = window.matchMedia("(min-width: 1024px)").matches
    if (!isDesktop) return

    this.highlightRow(event.currentTarget)
  }
}
