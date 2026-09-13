import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["primary"]
  static values = { autofocus: { type: Boolean, default: false } }

  connect() {
    const hasErrors = !!this.element.querySelector('[aria-invalid="true"], .yn-field-invalid, .field_with_errors input, .field_with_errors select, [role="alert"], .yn-alert, #form_error_alert')
    if (!this.autofocusValue && !hasErrors) {
      return
    }

    requestAnimationFrame(() => {
      // 1. Prefer the first invalid field
      const invalidField = this.element.querySelector('[aria-invalid="true"], .yn-field-invalid, .field_with_errors input, .field_with_errors select')
      if (invalidField) {
        invalidField.focus()
        return
      }

      // 2. Prefer error alert if present
      const errorAlert = this.element.querySelector('[role="alert"], .yn-alert, #form_error_alert')
      if (errorAlert) {
        errorAlert.setAttribute("tabindex", "-1")
        errorAlert.focus()
        return
      }

      // 3. Normal flow: focus detail heading or first interactive form control
      const heading = this.element.querySelector('#review_detail_title, h2, h1')
      if (heading) {
        heading.setAttribute("tabindex", "-1")
        heading.focus()
        return
      }

      const firstInput = this.element.querySelector('select, input:not([type="hidden"]), button')
      if (firstInput) {
        firstInput.focus()
      } else {
        this.element.focus()
      }
    })
  }
}
