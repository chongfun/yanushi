class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :properties, dependent: :destroy
  has_many :rentable_units, through: :properties
  has_many :tenancies, through: :rentable_units
  has_many :expenses, through: :properties
  has_many :scheduled_rents, through: :tenancies
  has_many :tenant_payments, through: :tenancies
  has_many :tenant_charges, through: :tenancies
  has_many :parties, dependent: :destroy
  has_many :payment_ingestions, dependent: :destroy
  has_many :payment_documents, dependent: :destroy

  validates :email, presence: true, uniqueness: true
  validates :password_digest, presence: true

  normalizes :email, with: ->(e) { e.strip.downcase }
end
