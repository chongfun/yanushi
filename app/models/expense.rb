class Expense < ApplicationRecord
  belongs_to :rental_property
  has_one :tenant_charge, dependent: :destroy

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :category, presence: true
  validates :expense_date, presence: true
  validates :reimburse_amount, numericality: { greater_than: 0 }, allow_blank: true, if: :tenant_reimbursable

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

  def reimbursed?
    tenant_charge.present?
  end

  def raw_reimburse_amount
    @reimburse_amount
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
end
