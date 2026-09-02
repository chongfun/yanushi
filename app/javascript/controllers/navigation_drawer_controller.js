import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog"]

  open(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    this.triggerElement = event?.currentTarget || document.activeElement
    if (this.hasDialogTarget) {
      this.dialogTarget.showModal()
      document.body.style.overflow = "hidden"
    }
  }

  close(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    if (this.hasDialogTarget) {
      this.dialogTarget.close()
    }
    document.body.style.overflow = ""
    if (this.triggerElement && typeof this.triggerElement.focus === "function") {
      try {
        this.triggerElement.focus()
      } catch (_) {}
    }
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    }
  }

  backdropClick(event) {
    if (this.hasDialogTarget && event.target === this.dialogTarget) {
      this.close()
    }
  }

  disconnect() {
    document.body.style.overflow = ""
  }
}
