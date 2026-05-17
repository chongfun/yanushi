class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :rental_properties, dependent: :destroy
  has_many :tenants, dependent: :destroy
  has_one :email_configuration, dependent: :destroy
  has_many :payment_emails, dependent: :destroy
  has_many :notifications, dependent: :destroy

  normalizes :email, with: ->(e) { e.strip.downcase }
end
