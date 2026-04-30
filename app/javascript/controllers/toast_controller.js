import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    timeout: { type: Number, default: 4000 }
  }

  connect() {
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
    this.element.style.transition = "opacity 0.3s ease, transform 0.3s ease"
    this.element.style.opacity = "0"
    this.element.style.transform = "translateX(1rem)"
    this.element.addEventListener("transitionend", () => {
      this.element.remove()
    }, { once: true })
  }
}
