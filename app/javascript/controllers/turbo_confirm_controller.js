import { Controller } from "@hotwired/stimulus"

let activeController = null
let pendingResolver = null

export default class extends Controller {
  static targets = ["message"]

  connect() {
    activeController = this
    this.element._turboConfirmController = this
    this.element.dataset.connected = "true"

    // Close on backdrop click
    this._boundClick = (e) => {
      if (e.target === this.element) {
        this.cancel(e)
      }
    }
    this.element.addEventListener("click", this._boundClick)

    // Handle Escape key
    this._boundCancel = (e) => {
      e.preventDefault()
      this.cancel(e)
    }
    this.element.addEventListener("cancel", this._boundCancel)
  }

  disconnect() {
    delete this.element.dataset.connected
    if (activeController === this) activeController = null
    if (this.element._turboConfirmController === this) this.element._turboConfirmController = null

    // Cancel pending confirmation on teardown
    this._resolve(false)

    if (this._boundClick) this.element.removeEventListener("click", this._boundClick)
    if (this._boundCancel) this.element.removeEventListener("cancel", this._boundCancel)
  }

  // Open dialog and return Promise<boolean>
  show(message) {
    return showConfirmDialog(message)
  }

  confirm(event) {
    if (event) event.preventDefault()
    this._resolve(true)
  }

  cancel(event) {
    if (event) event.preventDefault()
    this._resolve(false)
  }

  // ── Private ──

  // Settle pending Promise and close dialog
  _resolve(value) {
    const resolver = pendingResolver
    pendingResolver = null

    const dialog = this.element || document.getElementById("confirm-modal")
    if (dialog && dialog.open) {
      dialog.close()
    }

    if (resolver) {
      resolver(value)
    }
  }
}

// Turbo.setConfirmMethod handler
export function showConfirmDialog(message) {
  const dialog = document.getElementById("confirm-modal")
  if (!dialog) return Promise.resolve(window.confirm(message))

  // Cancel any previously pending confirmation
  if (pendingResolver) {
    const prev = pendingResolver
    pendingResolver = null
    prev(false)
  }

  const messageEl = dialog.querySelector("#confirm-message") || dialog.querySelector("[data-turbo-confirm-target='message']")
  if (messageEl) messageEl.textContent = message

  const settle = (val) => {
    const resolver = pendingResolver
    pendingResolver = null
    if (dialog.open) dialog.close()
    if (resolver) resolver(val)
  }

  const confirmBtn = dialog.querySelector("[data-action*='turbo-confirm#confirm']")
  const cancelBtn = dialog.querySelector("[data-action*='turbo-confirm#cancel']")

  if (confirmBtn) {
    confirmBtn.onclick = (e) => {
      e.preventDefault()
      settle(true)
    }
  }

  if (cancelBtn) {
    cancelBtn.onclick = (e) => {
      e.preventDefault()
      settle(false)
    }
  }

  if (!dialog.open) dialog.showModal()

  return new Promise((resolve) => {
    pendingResolver = resolve
  })
}
