class Tenant < ApplicationRecord
  belongs_to :user
  has_many :lease_tenants, dependent: :destroy
  has_many :leases, through: :lease_tenants
  has_many :tenant_payments, through: :leases

  accepts_nested_attributes_for allow_destroy: true, reject_if: :all_blank
end
