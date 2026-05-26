class LeaseTenant < ShardedRecord
  belongs_to :lease
  belongs_to :tenant

  validate :tenant_belongs_to_lease_owner

  private
    def tenant_belongs_to_lease_owner
      return unless lease&.rental_property&.user_id && tenant&.user_id

      if tenant.user_id != lease.rental_property.user_id
        errors.add(:tenant, "must belong to the same user as the lease")
      end
    end
end
