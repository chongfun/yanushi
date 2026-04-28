import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    timeout: { type: Number, default: 4000 }
  }

  connect() {
    // Add a small delay so the entrance animation can play smoothly
    requestAnimationFrame(() => {
      this.element.classList.add("toast-enter-active")
      this.element.classList.remove("toast-enter")
    })

    if (this.timeoutValue > 0) {
      this.timeoutId = setTimeout(() => {
        this.close()
      }, this.timeoutValue)
    }
  }

  disconnect() {
    if (this.timeoutId) {
      clearTimeout(this.timeoutId)
    }
  }

  close() {
    this.element.classList.add("toast-leave-active")
    this.element.addEventListener('transitionend', () => {
      this.element.remove()
    }, { once: true })
  }
}
