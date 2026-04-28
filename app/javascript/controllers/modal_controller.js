import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "content", "title"]

  connect() {
    // Optionally close when clicking outside the dialog content
    this.dialogTarget.addEventListener('click', (e) => {
      if (e.target === this.dialogTarget) {
        this.close()
      }
    })
  }

  open() {
    this.dialogTarget.showModal()
    this.element.classList.add("modal-open")
  }

  close() {
    this.element.classList.remove("modal-open")
    // small delay for closing animation
    setTimeout(() => {
      this.dialogTarget.close()
    }, 200)
  }

  // Action that can be called by a turbo stream or button
  show(event) {
    if (event.detail && event.detail.title) {
      this.titleTarget.textContent = event.detail.title
    }
    this.open()
  }
}
