class TenancyParty < ApplicationRecord
  belongs_to :tenancy
  belongs_to :party

  ROLES = %w[
    tenant
    guarantor
    occupant
  ].freeze

  enum :role, ROLES.index_by(&:itself), prefix: false, validate: true

  validates :role, presence: true
  validates :effective_from, presence: true
  validate :effective_until_after_effective_from
  validate :party_belongs_to_tenancy_owner
  validate :effective_dates_within_tenancy_bounds
  validate :no_overlapping_participation_for_same_role

  scope :active, ->(date = Date.current) {
    where("effective_from <= ?", date)
      .where("effective_until IS NULL OR effective_until >= ?", date)
  }

  def active?(date = Date.current, as_of: nil)
    target_date = as_of || date
    target_date = Date.current if target_date.is_a?(Hash)
    starts_on = effective_from
    ends_on = effective_until
    return false unless starts_on

    starts_on <= target_date && (ends_on.nil? || ends_on >= target_date)
  end

  private

    def effective_until_after_effective_from
      eff_from = effective_from
      eff_until = effective_until
      return unless eff_from && eff_until

      if eff_until < eff_from
        errors.add(:effective_until, "must be on or after effective from date")
      end
    end

    def party_belongs_to_tenancy_owner
      return unless tenancy&.rentable_unit&.property&.user_id && party&.user_id

      if party.user_id != tenancy.rentable_unit.property.user_id
        errors.add(:party, "must belong to the same user as the tenancy")
      end
    end

    def effective_dates_within_tenancy_bounds
      t = tenancy
      eff_from = effective_from
      eff_until = effective_until
      return unless t && eff_from

      comm_date = t.commencement_date
      term_date = t.termination_date

      if comm_date && eff_from < comm_date
        errors.add(:effective_from, "cannot be before tenancy commencement date (#{comm_date})")
      end

      if term_date
        if eff_from > term_date
          errors.add(:effective_from, "cannot be after tenancy termination date (#{term_date})")
        end

        if eff_until.nil?
          errors.add(:effective_until, "is required for a terminated tenancy")
        elsif eff_until > term_date
          errors.add(:effective_until, "cannot be after tenancy termination date (#{term_date})")
        end
      end
    end

    def no_overlapping_participation_for_same_role
      return unless tenancy_id && party_id && role && effective_from

      overlapping = TenancyParty.where(tenancy_id: tenancy_id, party_id: party_id, role: role)
      overlapping = overlapping.where.not(id: id) if persisted?

      start_date = effective_from
      end_date = effective_until

      overlap_scope = if end_date.present?
        overlapping.where(
          "(effective_from <= :end_date AND (effective_until IS NULL OR effective_until >= :start_date))",
          start_date: start_date, end_date: end_date
        )
      else
        overlapping.where(
          "(effective_until IS NULL OR effective_until >= :start_date)",
          start_date: start_date
        )
      end

      if overlap_scope.exists?
        errors.add(:base, "Party already has an active participant role for the specified dates")
      end
    end
end
