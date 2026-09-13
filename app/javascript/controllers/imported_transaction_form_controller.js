import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "partySelect",
    "tenancySelect",
    "kindSelect",
    "confirmButton",
    "aliasContainer",
    "aliasLabel",
    "aliasCheckbox",
    "proposedAliasInput",
    "receiptExplanation",
    "depositExplanation",
    "unknownExplanation",
    "depositContext"
  ]

  static values = {
    partyTenancies: Object,
    tenancyParties: Object,
    partyAliasProposals: Object,
    proposedAlias: String
  }

  connect() {
    this.updateKindUI()
    this.updateAliasUI()
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

    this.updateAliasUI()
  }

  tenancyChanged() {
    const selectedTenancyId = this.tenancySelectTarget.value
    const currentPartyId = this.partySelectTarget.value

    if (!currentPartyId && selectedTenancyId) {
      const associatedParties = this.tenancyPartiesValue[selectedTenancyId] || []
      if (associatedParties.length === 1) {
        this.partySelectTarget.value = associatedParties[0].toString()
        this.updateAliasUI()
      }
    }
  }

  kindChanged() {
    this.updateKindUI()
  }

  updateKindUI() {
    if (!this.hasKindSelectTarget) return
    const kind = this.kindSelectTarget.value

    // Presentation only: the label mirrors the chosen classification. The
    // button stays enabled so the server's validation (a 422 with the reason,
    // focused by inbox_focus) is the single rule, and no-JS behaves the same.
    if (this.hasConfirmButtonTarget) {
      if (kind === "unknown" || !kind) {
        this.confirmButtonTarget.textContent = "Choose classification"
      } else if (kind === "security_deposit") {
        this.confirmButtonTarget.textContent = "Confirm deposit"
      } else {
        this.confirmButtonTarget.textContent = "Confirm receipt"
      }
    }

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

  updateAliasUI() {
    if (!this.hasAliasContainerTarget || !this.hasPartySelectTarget) return

    const selectedPartyId = this.partySelectTarget.value
    const selectedOption = this.partySelectTarget.options[this.partySelectTarget.selectedIndex]
    const partyName = (selectedPartyId && selectedOption) ? selectedOption.text.trim() : null

    const proposals = this.hasPartyAliasProposalsValue ? (this.partyAliasProposalsValue || {}) : {}
    const partyProposal = selectedPartyId ? proposals[selectedPartyId] : null
    const effectiveProposal = partyProposal || (selectedPartyId ? null : (this.hasProposedAliasValue ? this.proposedAliasValue : null))

    if (partyName && partyName !== "Select payer" && effectiveProposal) {
      this.aliasContainerTarget.classList.remove("hidden")
      if (this.hasAliasLabelTarget) {
        this.aliasLabelTarget.textContent = `Remember “${effectiveProposal}” as ${partyName} for future imports`
      }
      if (this.hasProposedAliasInputTarget) {
        this.proposedAliasInputTarget.value = effectiveProposal
      }
    } else {
      this.aliasContainerTarget.classList.add("hidden")
      if (this.hasProposedAliasInputTarget) {
        this.proposedAliasInputTarget.value = ""
      }
    }
  }
}
