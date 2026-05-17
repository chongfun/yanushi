class TenantAlias < ApplicationRecord
  belongs_to :tenant

  validates :name, presence: true, uniqueness: { scope: :tenant_id }
end
