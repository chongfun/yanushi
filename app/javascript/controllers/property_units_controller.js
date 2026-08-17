import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="property-units"
// Dynamically updates the rentable unit dropdown when the property dropdown changes.
export default class extends Controller {
  static targets = ["propertySelect", "unitSelect"]
  static values = {
    units: Object // { "propertyId": [{ id: 1, name: "Unit A" }, ...], ... }
  }

  connect() {
    this.updateUnits()
  }

  propertyChanged() {
    this.updateUnits()
  }

  updateUnits() {
    const propertyId = this.propertySelectTarget.value
    const unitSelect = this.unitSelectTarget
    const units = this.unitsValue[propertyId] || []
    const currentUnitId = unitSelect.dataset.currentUnitId

    // Clear existing options and rebuild
    unitSelect.innerHTML = '<option value="">Entire property / No specific unit</option>'

    units.forEach(unit => {
      const option = document.createElement("option")
      option.value = unit.id
      option.textContent = unit.name
      if (String(unit.id) === String(currentUnitId)) {
        option.selected = true
      }
      unitSelect.appendChild(option)
    })
  }
}
