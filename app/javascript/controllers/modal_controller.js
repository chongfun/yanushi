import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "content", "title"]

  connect() {
    this._triggerElement = null

    // Close when clicking outside the dialog content
    this._boundDialogClick = (e) => {
      if (e.target === this.dialogTarget) {
        this.close()
      }
    }
    this.dialogTarget.addEventListener('click', this._boundDialogClick)

    // Handle native dialog cancel event (e.g. Escape key)
    this._boundDialogCancel = (e) => {
      e.preventDefault()
      this.close()
    }
    this.dialogTarget.addEventListener('cancel', this._boundDialogCancel)

    this._boundFrameLoad = (e) => {
      const targetFrame = e.target
      const modalFrame = this.hasContentTarget ? this.contentTarget.querySelector("turbo-frame") : document.getElementById("modal-frame")
      if (targetFrame === modalFrame || (modalFrame && modalFrame.contains(targetFrame))) {
        this._closing = false
        if (modalFrame && modalFrame.innerHTML.trim() !== "") {
          const title = modalFrame.dataset.modalTitle ||
                        modalFrame.getAttribute("data-modal-title") ||
                        modalFrame.querySelector("[data-modal-title]")?.getAttribute("data-modal-title") ||
                        modalFrame.querySelector("[data-modal-title]")?.dataset.modalTitle ||
                        this._triggerElement?.getAttribute("data-modal-title")
          if (title && this.hasTitleTarget) {
            this.titleTarget.textContent = title
          }
          this.open()
        }
      }
    }
    document.addEventListener("turbo:frame-load", this._boundFrameLoad)
    document.addEventListener("turbo:frame-render", this._boundFrameLoad)

    // Listen for custom turbo stream action "close_modal" and frame updates
    this.streamListener = (event) => {
      const action = event.target.getAttribute("action")
      const target = event.target.getAttribute("target")
      if (action === "close_modal") {
        this.close()
        // Prevent Turbo from trying to find a built-in action and failing
        event.preventDefault()
      } else if (target === "modal-frame" || target === "modal-content") {
        requestAnimationFrame(() => {
          this._focusFirstInvalidOrAutofocus()
        })
      }
    }
    document.addEventListener("turbo:before-stream-render", this.streamListener)

    // Track trigger element for focus restoration
    this._clickListener = (event) => {
      const trigger = event.target.closest("[data-turbo-frame='modal-frame']")
      if (trigger) {
        this._triggerElement = trigger
      }
    }
    document.addEventListener("click", this._clickListener, true)
  }

  disconnect() {
    if (this._closeTimeout) clearTimeout(this._closeTimeout)
    if (this._boundDialogClick) this.dialogTarget.removeEventListener('click', this._boundDialogClick)
    if (this._boundDialogCancel) this.dialogTarget.removeEventListener('cancel', this._boundDialogCancel)
    if (this._boundFrameLoad) {
      document.removeEventListener("turbo:frame-load", this._boundFrameLoad)
      document.removeEventListener("turbo:frame-render", this._boundFrameLoad)
    }
    if (this._trapListener) this.dialogTarget.removeEventListener("keydown", this._trapListener)
    document.removeEventListener("turbo:before-stream-render", this.streamListener)
    document.removeEventListener("click", this._clickListener, true)
  }

  open() {
    if (!this.dialogTarget.open) {
      this.dialogTarget.showModal()
    }

    // Focus invalid field or autofocus target
    requestAnimationFrame(() => {
      this._focusFirstInvalidOrAutofocus()
    })

    // Trap focus inside dialog
    if (!this._trapListener) {
      this._trapListener = (e) => this._handleKeydown(e)
      this.dialogTarget.addEventListener("keydown", this._trapListener)
    }
  }

  _focusFirstInvalidOrAutofocus() {
    if (!this.dialogTarget.open) return
    const firstInvalid = this.dialogTarget.querySelector("[aria-invalid='true'], .yn-field-invalid")
    if (firstInvalid) {
      firstInvalid.focus()
      return
    }
    const autofocusEl = this.dialogTarget.querySelector("[autofocus]")
    const firstFocusable = autofocusEl || this._firstFocusable()
    if (firstFocusable) firstFocusable.focus()
  }

  close(event) {
    if (event) event.preventDefault()
    this._closing = true

    if (this._trapListener) {
      this.dialogTarget.removeEventListener("keydown", this._trapListener)
      this._trapListener = null
    }

    if (this.dialogTarget.open) {
      this.dialogTarget.close()
    }

    const frame = this.contentTarget.querySelector("turbo-frame")
    if (frame) {
      frame.innerHTML = ""
      frame.src = ""
      frame.removeAttribute("src")
      frame.removeAttribute("complete")
    }
    if (this.hasTitleTarget) this.titleTarget.textContent = ""

    // Restore focus to trigger or fallback
    const trigger = this._triggerElement
    this._triggerElement = null

    requestAnimationFrame(() => {
      this._closing = false
      if (trigger && document.body.contains(trigger)) {
        trigger.focus()
      } else {
        const fallback = document.getElementById("tenancy_balance") ||
                         document.querySelector("#tenancy_actions summary") ||
                         document.getElementById("tenancy_actions") ||
                         document.querySelector("main")
        if (fallback) {
          if (!fallback.hasAttribute("tabindex") && fallback.tagName !== "BUTTON" && fallback.tagName !== "A" && fallback.tagName !== "SUMMARY") {
            fallback.setAttribute("tabindex", "-1")
          }
          fallback.focus()
        }
      }
    })
  }

  // ── Focus trap helpers ──

  _handleKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      return
    }

    if (event.key !== "Tab") return

    const focusable = this._focusableElements()
    if (focusable.length === 0) return

    const first = focusable[0]
    const last = focusable[focusable.length - 1]

    if (event.shiftKey) {
      // Shift+Tab: wrap from first to last
      if (document.activeElement === first) {
        event.preventDefault()
        last.focus()
      }
    } else {
      // Tab: wrap from last to first
      if (document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }
  }

  _focusableElements() {
    return Array.from(
      this.dialogTarget.querySelectorAll(
        'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'
      )
    )
  }

  _firstFocusable() {
    const elements = this._focusableElements()
    return elements.length > 0 ? elements[0] : null
  }
}
