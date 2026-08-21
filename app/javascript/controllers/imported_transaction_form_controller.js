import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "partySelect",
    "tenancySelect",
    "kindSelect",
    "receiptExplanation",
    "depositExplanation",
    "unknownExplanation",
    "depositContext"
  ]

  static values = {
    partyTenancies: Object,
    tenancyParties: Object
  }

  connect() {
    this.updateKindUI()
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

  kindChanged() {
    this.updateKindUI()
  }

  updateKindUI() {
    if (!this.hasKindSelectTarget) return
    const kind = this.kindSelectTarget.value

    if (this.hasReceiptExplanationTarget) {
      this.receiptExplanationTarget.classList.toggle("hidden", kind !== "tenant_receipt")
    }
    if (this.hasDepositExplanationTarget) {
      this.depositExplanationTarget.classList.toggle("hidden", kind !== "security_deposit")
    }
    if (this.hasUnknownExplanationTarget) {
      this.unknownExplanationTarget.classList.toggle("hidden", kind !== "unknown" && kind !== "")
    }
    if (this.hasDepositContextTarget) {
      this.depositContextTarget.classList.toggle("hidden", kind !== "security_deposit")
    }
  }
}
