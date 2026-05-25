class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :rental_properties, dependent: :destroy
  has_many :leases, through: :rental_properties
  has_many :expenses, through: :rental_properties
  has_many :scheduled_rents, through: :leases
  has_many :tenant_payments, through: :leases
  has_many :tenant_charges, through: :leases
  has_many :tenants, dependent: :destroy
  has_many :payment_ingestions, dependent: :destroy
  has_many :payment_documents, dependent: :destroy

  validates :email, presence: true, uniqueness: true
  validates :password_digest, presence: true

  normalizes :email, with: ->(e) { e.strip.downcase }
end
