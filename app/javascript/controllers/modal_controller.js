import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "content", "title"]

  connect() {
    // Close when clicking outside the dialog content
    this.dialogTarget.addEventListener('click', (e) => {
      if (e.target === this.dialogTarget) {
        this.close()
      }
    })

    // Auto-open the modal when the turbo frame inside it loads content
    this.element.addEventListener("turbo:frame-load", (e) => {
      const frame = this.contentTarget.querySelector("turbo-frame")
      if (frame && frame.innerHTML.trim() !== "") {
        const title = frame.dataset.modalTitle
        if (title && this.hasTitleTarget) {
          this.titleTarget.textContent = title
        }
        this.open()
      }
    })

    // Listen for custom turbo stream action "close_modal"
    this.streamListener = (event) => {
      const action = event.target.getAttribute("action")
      if (action === "close_modal") {
        this.close()
        // Prevent Turbo from trying to find a built-in action and failing
        event.preventDefault()
      }
    }
    document.addEventListener("turbo:before-stream-render", this.streamListener)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.streamListener)
  }

  open() {
    if (!this.dialogTarget.open) {
      this.dialogTarget.showModal()
      this.element.classList.add("modal-open")
    }
  }

  close() {
    this.element.classList.remove("modal-open")
    // Clear frame content and close after animation
    setTimeout(() => {
      if (this.dialogTarget.open) {
        this.dialogTarget.close()
      }
      const frame = this.contentTarget.querySelector("turbo-frame")
      if (frame) frame.innerHTML = ""
      if (this.hasTitleTarget) this.titleTarget.textContent = ""
    }, 200)
  }
}
