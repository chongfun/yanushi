class RentalProperty < ApplicationRecord
  belongs_to :user
  has_many :leases, dependent: :destroy
  has_many :expenses, dependent: :destroy
  has_many :utility_payments, dependent: :destroy
  enum :property_type, { commercial: 0, residential: 1 }
end
