class RentTerm < ApplicationRecord
  belongs_to :tenancy

  FREQUENCIES = %w[monthly].freeze

  enum :frequency, FREQUENCIES.index_by(&:itself), prefix: false, validate: true

  validates :amount_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :frequency, presence: true
  validates :due_day, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 31 }
  validates :effective_from, presence: true
  validate :effective_until_after_effective_from
  validate :effective_dates_within_tenancy_bounds
  validate :no_overlapping_rent_terms

  scope :active, ->(date = Date.current) {
    where("effective_from <= ?", date)
      .where("effective_until IS NULL OR effective_until >= ?", date)
  }

  def amount
    amount_cents.present? ? (amount_cents / 100.0) : nil
  end

  def amount=(val)
    if val.present? && val.to_s.strip.present?
      begin
        self.amount_cents = (BigDecimal(val.to_s) * 100).round
      rescue StandardError
        self.amount_cents = 0
      end
    else
      self.amount_cents = 0
    end
  end

  def active?(date = Date.current, as_of: nil)
    target_date = as_of || date
    target_date = Date.current if target_date.is_a?(Hash)
    starts_on = effective_from
    ends_on = effective_until
    return false unless starts_on

    starts_on <= target_date && (ends_on.nil? || ends_on >= target_date)
  end

  def due_date_for(year, month)
    max_days = Date.new(year, month, -1).day
    Date.new(year, month, [ due_day, max_days ].min)
  end

  def accounting_user
    tenancy&.property&.user
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

    def no_overlapping_rent_terms
      return unless tenancy_id && effective_from

      overlapping = RentTerm.where(tenancy_id: tenancy_id)
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
        errors.add(:base, "Rent term overlaps with an existing term for this tenancy")
      end
    end
end
