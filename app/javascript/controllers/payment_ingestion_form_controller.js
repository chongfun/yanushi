import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["partySelect", "tenancySelect"]
  static values = {
    partyTenancies: Object,
    tenancyParties: Object
  }

  partyChanged() {
    const selectedPartyId = this.partySelectTarget.value
    const currentTenancyId = this.tenancySelectTarget.value

    if (!currentTenancyId && selectedPartyId) {
      const associatedTenancies = this.partyTenanciesValue[selectedPartyId] || []
      if (associatedTenancies.length === 1) {
        this.tenancySelectTarget.value = associatedTenancies[0].toString()
      }
    }
  }

  tenancyChanged() {
    const selectedTenancyId = this.tenancySelectTarget.value
    const currentPartyId = this.partySelectTarget.value

    if (!currentPartyId && selectedTenancyId) {
      const associatedParties = this.tenancyPartiesValue[selectedTenancyId] || []
      if (associatedParties.length === 1) {
        this.partySelectTarget.value = associatedParties[0].toString()
      }
    }
  }
}
