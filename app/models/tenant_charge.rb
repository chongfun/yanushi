class TenantCharge < ApplicationRecord
  belongs_to :tenancy
  belongs_to :expense

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :charge_date, presence: true

  def accounting_user
    tenancy&.property&.user
  end
end
