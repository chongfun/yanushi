class Tenant < ApplicationRecord
  belongs_to :user
  has_many :lease_tenants, dependent: :destroy
  has_many :leases, through: :lease_tenants
  has_many :tenant_payments, through: :leases

  has_many :tenant_aliases, dependent: :destroy
  has_many :payment_ingestions, dependent: :nullify

  validates :name, presence: true

  accepts_nested_attributes_for :tenant_aliases, allow_destroy: true, reject_if: :all_blank

  def alias_candidate?(alias_name)
    return false if alias_name.blank?

    tenant_name = name
    return false if tenant_name.blank?

    clean_name = alias_name.strip.downcase
    return false if clean_name == tenant_name.strip.downcase

    if tenant_aliases.loaded?
      tenant_aliases.none? { |ta| ta.alias_name.strip.downcase == clean_name }
    else
      !tenant_aliases.where("LOWER(TRIM(alias_name)) = ?", clean_name).exists?
    end
  end
end
