import { Controller } from "@hotwired/stimulus"

// Focuses the next actionable element when autoFocus is enabled
export default class extends Controller {
  static values = { autoFocus: Boolean }

  connect() {
    if (this.autoFocusValue) {
      // Defer until DOM paints
      requestAnimationFrame(() => this.manageFocus())
    }
  }

  manageFocus() {
    // Focus first invalid field if present
    const invalidControl = this.element.querySelector(
      "[aria-invalid='true']:not([type='hidden']), .yn-field-invalid:not([type='hidden'])"
    )
    if (invalidControl) {
      invalidControl.focus()
      return
    }

    // Focus next unresolved control
    const firstControl = this.element.querySelector(
      "[id^='review_item_'] select, [id^='review_item_'] input[type='submit']"
    )
    if (firstControl) {
      firstControl.focus()
      return
    }

    // Focus heading if all items resolved
    const heading = this.element.querySelector("#se-review-heading")
    if (heading) {
      heading.focus()
      return
    }

    // Fallback: focus section
    this.element.focus()
  }
}
