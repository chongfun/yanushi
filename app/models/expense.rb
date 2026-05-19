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

        old_expense_amount = amount_before_last_save
        previous_charge_amount = charge.amount_before_last_save || charge.amount

        if @reimburse_amount.nil?
          # Programmatic update or not submitted via the form
          if old_expense_amount && (previous_charge_amount.nil? || previous_charge_amount == old_expense_amount)
            charge_amount = amount
          else
            charge_amount = previous_charge_amount || amount
          end
        elsif @reimburse_amount.to_s.strip.empty?
          # Deliberately cleared in the form
          charge_amount = amount
        else
          # Submitted in the form
          submitted_amount = BigDecimal(@reimburse_amount.to_s) rescue nil
          if submitted_amount
            if old_expense_amount && submitted_amount == old_expense_amount && (previous_charge_amount.nil? || previous_charge_amount == old_expense_amount)
              # Pre-populated value matches old expense amount, which was matching the old charge.
              # Sync to the new expense amount!
              charge_amount = amount
            else
              charge_amount = submitted_amount
            end
          else
            charge_amount = amount
          end
        end

        charge.update!(
          lease_id: target_lease_id,
          amount: charge_amount,
          charge_date: expense_date,
          description: "Reimbursement for #{category}: #{description}"
        )
      end
    else
      tenant_charge&.destroy
    end
  end
end
