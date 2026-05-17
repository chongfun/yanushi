class Tenant < ApplicationRecord
  belongs_to :user
  has_many :lease_tenants, dependent: :destroy
  has_many :leases, through: :lease_tenants
  has_many :utility_payments, through: :leases
  has_many :tenant_aliases, dependent: :destroy

  accepts_nested_attributes_for :tenant_aliases, allow_destroy: true, reject_if: :all_blank

  def all_names
    [ name, *tenant_aliases.pluck(:name) ].compact.map { |n| n.downcase.strip }
  end
end
