class TenantAlias < ShardedRecord
  belongs_to :tenant

  validates :alias_name, presence: true
  validates :alias_name, uniqueness: { scope: :tenant_id, case_sensitive: false }

  normalizes :alias_name, with: ->(name) { name.strip }
end
