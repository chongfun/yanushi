import { Controller } from "@hotwired/stimulus"

// Moves keyboard focus to the next actionable control after the review
// section is replaced by a Turbo Stream (autoFocus is set by the stream).
export default class extends Controller {
  static values = { autoFocus: Boolean }

  connect() {
    if (this.autoFocusValue) {
      // The section is already in the document when a stream replace connects
      // this controller, so focus can move synchronously. Deferring a frame
      // leaves a window where focus sits on a removed node.
      this.manageFocus()
    }

    // Turbo preserves focus across a stream render by element id. If focus is
    // on a node this section will re-render (the heading, a select), Turbo
    // would put it back there after the response and override the move made
    // above. Releasing focus when one of this section's forms submits leaves
    // the response in charge of where focus lands.
    this._submitStartListener = (event) => {
      if (this.element.contains(event.target) && this.element.contains(document.activeElement)) {
        document.activeElement.blur()
      }
    }
    document.addEventListener("turbo:submit-start", this._submitStartListener)
  }

  disconnect() {
    document.removeEventListener("turbo:submit-start", this._submitStartListener)
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
