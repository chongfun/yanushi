class TenantPayment < ApplicationRecord
  belongs_to :lease

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_date, presence: true
  validates :payment_method, presence: true
  validates :transaction_number, length: { maximum: 50 }, format: { with: /\A[a-zA-Z0-9_\-]*\z/, message: "must be alphanumeric with dashes or underscores" }, allow_blank: true
end
