import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="date-range-filter"
export default class extends Controller {
  static targets = ["yearSelect", "fromInput", "throughInput"]

  yearChanged() {
    if (this.hasFromInputTarget) {
      this.fromInputTarget.value = ""
    }
    if (this.hasThroughInputTarget) {
      this.throughInputTarget.value = ""
    }
    this.element.requestSubmit()
  }

  dateChanged() {
    if (this.hasYearSelectTarget) {
      this.yearSelectTarget.value = ""
    }
  }
}
