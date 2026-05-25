import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tenantSelect", "leaseSelect"]
  static values = {
    tenantLeases: Object,
    leaseTenants: Object
  }

  connect() {
    // Store original options
    this.allLeaseOptions = Array.from(this.leaseSelectTarget.options).map(opt => ({
      value: opt.value,
      text: opt.text
    }))
    this.allTenantOptions = Array.from(this.tenantSelectTarget.options).map(opt => ({
      value: opt.value,
      text: opt.text
    }))

    // Perform initial filtering based on selection
    this.filterLeases(false)
    this.filterTenants(false)
  }

  tenantChanged() {
    this.filterLeases(true)
  }

  leaseChanged() {
    this.filterTenants(true)
  }

  filterLeases(resetSelectionIfInvalid) {
    const selectedTenantId = this.tenantSelectTarget.value
    const currentSelectedLeaseId = this.leaseSelectTarget.value

    if (!selectedTenantId) {
      // Restore all leases
      this.populateSelect(this.leaseSelectTarget, this.allLeaseOptions, currentSelectedLeaseId)
      return
    }

    const allowedLeaseIds = this.tenantLeasesValue[selectedTenantId] || []
    
    // Filter options
    const filteredOptions = this.allLeaseOptions.filter(opt => {
      return !opt.value || allowedLeaseIds.includes(parseInt(opt.value))
    })

    const isCurrentValid = allowedLeaseIds.includes(parseInt(currentSelectedLeaseId))
    let nextSelectedId = isCurrentValid ? currentSelectedLeaseId : ""

    if (!isCurrentValid && allowedLeaseIds.length === 1) {
      nextSelectedId = allowedLeaseIds[0].toString()
    }

    this.populateSelect(this.leaseSelectTarget, filteredOptions, resetSelectionIfInvalid ? nextSelectedId : currentSelectedLeaseId)
  }

  filterTenants(resetSelectionIfInvalid) {
    const selectedLeaseId = this.leaseSelectTarget.value
    const currentSelectedTenantId = this.tenantSelectTarget.value

    if (!selectedLeaseId) {
      // Restore all tenants
      this.populateSelect(this.tenantSelectTarget, this.allTenantOptions, currentSelectedTenantId)
      return
    }

    const allowedTenantIds = this.leaseTenantsValue[selectedLeaseId] || []

    // Filter options
    const filteredOptions = this.allTenantOptions.filter(opt => {
      return !opt.value || allowedTenantIds.includes(parseInt(opt.value))
    })

    const isCurrentValid = allowedTenantIds.includes(parseInt(currentSelectedTenantId))
    let nextSelectedId = isCurrentValid ? currentSelectedTenantId : ""

    if (!isCurrentValid && allowedTenantIds.length === 1) {
      nextSelectedId = allowedTenantIds[0].toString()
    }

    this.populateSelect(this.tenantSelectTarget, filteredOptions, resetSelectionIfInvalid ? nextSelectedId : currentSelectedTenantId)
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
