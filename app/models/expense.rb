class Expense < ApplicationRecord
  belongs_to :property
  has_many :charges, foreign_key: :source_expense_id, dependent: :restrict_with_error
  has_many :reimbursement_charges, -> { where(charge_kind: "reimbursement") }, class_name: "Charge", foreign_key: :source_expense_id, dependent: :restrict_with_error

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

  attr_accessor :tenant_reimbursable, :reimburse_tenancy_id, :reimburse_amount

  validate :prevent_property_change_with_charges, on: :update
  validate :prevent_amount_reduction_below_reimbursements, on: :update

  def reimbursed?
    reimbursement_charges.exists?
  end

  def reimbursement_charge
    reimbursement_charges.first
  end

  def total_active_reimbursement_cents
    reimbursement_charges.active.sum(:amount_cents)
  end

  def remaining_reimbursable_cents
    expense_cents = amount ? (BigDecimal(amount.to_s) * 100).round : 0
    [ expense_cents - total_active_reimbursement_cents, 0 ].max
  end

  def remaining_reimbursable_amount
    BigDecimal(remaining_reimbursable_cents) / 100
  end

  def fully_reimbursed?
    reimbursed? && remaining_reimbursable_cents <= 0
  end

  def raw_reimburse_amount
    @reimburse_amount
  end

  def tenant_reimbursable
    @tenant_reimbursable.nil? ? reimbursed? : ActiveModel::Type::Boolean.new.cast(@tenant_reimbursable)
  end

  def reimburse_tenancy_id
    @reimburse_tenancy_id.presence || reimbursement_charges.first&.tenancy_id
  end

  def reimburse_lease_id
    reimburse_tenancy_id
  end

  def reimburse_lease_id=(val)
    self.reimburse_tenancy_id = val
  end

  def reimburse_amount
    @reimburse_amount.presence || reimbursement_charges.first&.amount || amount
  end

  def accounting_user
    property&.user
  end

  private

    def prevent_property_change_with_charges
      if will_save_change_to_property_id? && charges.exists?
        errors.add(:property, "cannot change after reimbursement charges have been posted")
      end
    end

    def prevent_amount_reduction_below_reimbursements
      if will_save_change_to_amount? && amount.present?
        new_cents = (BigDecimal(amount.to_s) * 100).round
        active_cents = total_active_reimbursement_cents
        if new_cents < active_cents
          active_dollars = sprintf("%.2f", active_cents / 100.0)
          errors.add(:amount, "cannot be reduced below total active reimbursement charges ($#{active_dollars})")
        end
      end
    end
end
