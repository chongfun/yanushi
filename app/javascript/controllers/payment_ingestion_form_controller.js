import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["partySelect", "tenancySelect"]
  static values = {
    partyTenancies: Object,
    tenancyParties: Object
  }

  connect() {
    // Store original options
    this.allTenancyOptions = Array.from(this.tenancySelectTarget.options).map(opt => ({
      value: opt.value,
      text: opt.text
    }))
    this.allPartyOptions = Array.from(this.partySelectTarget.options).map(opt => ({
      value: opt.value,
      text: opt.text
    }))

    // Perform initial filtering based on selection
    this.filterTenancies(false)
    this.filterParties(false)
  }

  partyChanged() {
    this.filterTenancies(true)
  }

  tenancyChanged() {
    this.filterParties(true)
  }

  filterTenancies(resetSelectionIfInvalid) {
    const selectedPartyId = this.partySelectTarget.value
    const currentSelectedTenancyId = this.tenancySelectTarget.value

    if (!selectedPartyId) {
      // Restore all tenancies
      this.populateSelect(this.tenancySelectTarget, this.allTenancyOptions, currentSelectedTenancyId)
      return
    }

    const allowedTenancyIds = this.partyTenanciesValue[selectedPartyId] || []

    // Filter options
    const filteredOptions = this.allTenancyOptions.filter(opt => {
      return !opt.value || allowedTenancyIds.includes(parseInt(opt.value))
    })

    const isCurrentValid = allowedTenancyIds.includes(parseInt(currentSelectedTenancyId))
    let nextSelectedId = isCurrentValid ? currentSelectedTenancyId : ""

    if (!isCurrentValid && allowedTenancyIds.length === 1) {
      nextSelectedId = allowedTenancyIds[0].toString()
    }

    this.populateSelect(this.tenancySelectTarget, filteredOptions, resetSelectionIfInvalid ? nextSelectedId : currentSelectedTenancyId)
  }

  filterParties(resetSelectionIfInvalid) {
    const selectedTenancyId = this.tenancySelectTarget.value
    const currentSelectedPartyId = this.partySelectTarget.value

    if (!selectedTenancyId) {
      // Restore all parties
      this.populateSelect(this.partySelectTarget, this.allPartyOptions, currentSelectedPartyId)
      return
    }

    const allowedPartyIds = this.tenancyPartiesValue[selectedTenancyId] || []

    // Filter options
    const filteredOptions = this.allPartyOptions.filter(opt => {
      return !opt.value || allowedPartyIds.includes(parseInt(opt.value))
    })

    const isCurrentValid = allowedPartyIds.includes(parseInt(currentSelectedPartyId))
    let nextSelectedId = isCurrentValid ? currentSelectedPartyId : ""

    if (!isCurrentValid && allowedPartyIds.length === 1) {
      nextSelectedId = allowedPartyIds[0].toString()
    }

    this.populateSelect(this.partySelectTarget, filteredOptions, resetSelectionIfInvalid ? nextSelectedId : currentSelectedPartyId)
  }

  populateSelect(selectElement, options, selectedValue) {
    selectElement.innerHTML = ""

    options.forEach(opt => {
      const option = document.createElement("option")
      option.value = opt.value
      option.text = opt.text
      if (opt.value === selectedValue.toString()) {
        option.selected = true
      }
      selectElement.add(option)
    })
  }
}
