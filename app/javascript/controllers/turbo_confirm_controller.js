import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["message"]

  connect() {
    // Close on backdrop click
    this.element.addEventListener("click", (e) => {
      if (e.target === this.element) {
        this.cancel()
      }
    })
  }

  show(message) {
    this.messageTarget.textContent = message
    this.element.showModal()
    
    return new Promise((resolve) => {
      this.resolver = resolve
    })
  }

  confirm(event) {
    if (event) event.preventDefault()
    this.element.close()
    if (this.resolver) {
      this.resolver(true)
      this.resolver = null
    }
  }

  cancel(event) {
    if (event) event.preventDefault()
    this.element.close()
    if (this.resolver) {
      this.resolver(false)
      this.resolver = null
    }
  }
}
