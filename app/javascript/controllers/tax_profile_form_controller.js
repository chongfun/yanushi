import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="tax-profile-form"
export default class extends Controller {
  static targets = ["typeSelect", "otherContainer", "otherInput"]

  connect() {
    this.toggleOther()
  }

  typeChanged() {
    this.toggleOther()
  }

  toggleOther() {
    if (!this.hasTypeSelectTarget || !this.hasOtherContainerTarget) return

    const isOther = this.typeSelectTarget.value === "other"
    if (isOther) {
      this.otherContainerTarget.classList.remove("hidden")
      if (this.hasOtherInputTarget) {
        this.otherInputTarget.required = true
      }
    } else {
      this.otherContainerTarget.classList.add("hidden")
      if (this.hasOtherInputTarget) {
        this.otherInputTarget.required = false
        this.otherInputTarget.value = ""
      }
    }
  }
}
