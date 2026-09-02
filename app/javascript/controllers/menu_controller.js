import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.boundHandleClickOutside = this.handleClickOutside.bind(this)
    this.boundHandleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("click", this.boundHandleClickOutside)
    document.addEventListener("keydown", this.boundHandleKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this.boundHandleClickOutside)
    document.removeEventListener("keydown", this.boundHandleKeydown)
  }

  handleClickOutside(event) {
    if (this.element.open && !this.element.contains(event.target)) {
      this.element.removeAttribute("open")
    }
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.element.open) {
      this.element.removeAttribute("open")
      const summary = this.element.querySelector("summary")
      if (summary) summary.focus()
    }
  }
}
