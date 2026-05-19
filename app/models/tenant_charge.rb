class TenantCharge < ApplicationRecord
  belongs_to :lease
  belongs_to :expense

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :charge_date, presence: true
end
