import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["treatmentSelect", "categoryWrapper"]

  connect() {
    this.toggle()
  }

  toggle() {
    if (!this.hasTreatmentSelectTarget || !this.hasCategoryWrapperTarget) return
    const isCategory = this.treatmentSelectTarget.value === "map_to_schedule_e_category"
    this.categoryWrapperTarget.classList.toggle("hidden", !isCategory)
  }
}
