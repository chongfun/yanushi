class TenantPayment < ApplicationRecord
  belongs_to :lease

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_date, presence: true
  validates :payment_method, presence: true
end
