class Tenant < ApplicationRecord
  belongs_to :user
  has_many :lease_tenants, dependent: :destroy
  has_many :leases, through: :lease_tenants
  has_many :tenant_payments, through: :leases

  has_many :tenant_aliases, dependent: :destroy
  has_many :payment_ingestions, dependent: :nullify

  accepts_nested_attributes_for :tenant_aliases, allow_destroy: true, reject_if: :all_blank
end
