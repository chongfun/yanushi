class Expense < ApplicationRecord
  belongs_to :rental_property
  has_one :tenant_charge, dependent: :destroy

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :category, presence: true
  validates :expense_date, presence: true

  enum :category, {
    advertising: "advertising",
    auto_and_travel: "auto_and_travel",
    cleaning_and_maintenance: "cleaning_and_maintenance",
    commissions: "commissions",
    insurance: "insurance",
    legal_and_other_professional_fees: "legal_and_other_professional_fees",
    management_fees: "management_fees",
    mortgage_interest: "mortgage_interest",
    other_interest: "other_interest",
    repairs: "repairs",
    supplies: "supplies",
    taxes: "taxes",
    utilities: "utilities",
    depreciation_expense: "depreciation_expense",
    other: "other"
  }

  attr_accessor :tenant_reimbursable, :reimburse_lease_id, :reimburse_amount

  after_save :manage_tenant_charge

  def reimbursed?
    tenant_charge.present?
  end

  def tenant_reimbursable
    @tenant_reimbursable.nil? ? reimbursed? : ActiveModel::Type::Boolean.new.cast(@tenant_reimbursable)
  end

  def reimburse_lease_id
    @reimburse_lease_id.presence || tenant_charge&.lease_id
  end

  def reimburse_amount
    @reimburse_amount.presence || tenant_charge&.amount || amount
  end

  private

  def manage_tenant_charge
    if ActiveModel::Type::Boolean.new.cast(tenant_reimbursable)
      target_lease_id = reimburse_lease_id.presence || rental_property.leases.first&.id

      if target_lease_id
        charge = tenant_charge || build_tenant_charge
        charge.update!(
          lease_id: target_lease_id,
          amount: reimburse_amount.presence || amount,
          charge_date: expense_date,
          description: "Reimbursement for #{category}: #{description}"
        )
      end
    else
      tenant_charge&.destroy
    end
  end
end
