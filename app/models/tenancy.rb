class Tenancy < ApplicationRecord
  belongs_to :rentable_unit
  has_one :property, through: :rentable_unit
  has_many :tenancy_parties, dependent: :destroy
  has_many :parties, through: :tenancy_parties
  has_many :rent_terms, dependent: :destroy

  has_many :charges, dependent: :restrict_with_error
  has_many :receipts, dependent: :restrict_with_error
  has_many :accounting_postings, class_name: "Posting", dependent: :restrict_with_error
  has_one :security_deposit, dependent: :restrict_with_error
  has_many :security_deposit_transactions, through: :security_deposit, source: :transactions
  has_many :payment_ingestions, dependent: :nullify

  AGREEMENT_TYPES = %w[
    fixed_term
    month_to_month
    other
  ].freeze

  enum :agreement_type, AGREEMENT_TYPES.index_by(&:itself), prefix: false, validate: true

  validates :commencement_date, presence: true
  validates :agreement_type, presence: true
  validates :late_period_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :rentable_unit_is_active, on: :create
  validate :termination_date_after_commencement_date
  validate :fixed_term_requires_termination_date
  validate :no_overlapping_tenancies_on_same_unit

  scope :active, ->(date = Date.current) {
    where("commencement_date <= ?", date)
      .where("termination_date IS NULL OR termination_date >= ?", date)
  }

  def active?(date = Date.current, as_of: nil)
    target_date = as_of || date
    target_date = Date.current if target_date.is_a?(Hash)
    starts_on = commencement_date
    ends_on = termination_date
    return false unless starts_on

    starts_on <= target_date && (ends_on.nil? || ends_on >= target_date)
  end

  def continuous_tenant_coverage?(candidate_parties = nil)
    starts_on = commencement_date
    return false unless starts_on

    ends_on = termination_date
    pool = candidate_parties || tenancy_parties
    tenant_intervals = pool.select(&:tenant?).map do |tp|
      [ tp.effective_from, tp.effective_until ]
    end

    return false if tenant_intervals.empty?

    sorted = tenant_intervals.sort_by { |start_date, _| start_date || Date.new(1900, 1, 1) }
    first_start = sorted.first.first
    return false if first_start.nil? || first_start > starts_on

    cursor = starts_on
    sorted.each do |eff_from, eff_until|
      next if eff_until.present? && eff_until < cursor

      return false if eff_from > cursor

      if eff_until.nil?
        return true if ends_on.nil? || ends_on >= cursor
        cursor = ends_on + 1.day
        break
      else
        cursor = [ cursor, eff_until + 1.day ].max
        return true if ends_on.present? && cursor > ends_on
      end
    end

    if ends_on.present?
      cursor > ends_on
    else
      false
    end
  end

  def current_rent_term(date = Date.current, as_of: nil)
    target_date = as_of || date
    target_date = Date.current if target_date.is_a?(Hash)
    rent_terms.find { |term| term.active?(target_date) }
  end

  def most_recent_rent_term
    rent_terms.order(effective_from: :desc).first
  end

  def financial_history?
    charges.exists? || receipts.exists? || accounting_postings.exists? || security_deposit_transactions.exists?
  end

  def balance_cents(as_of: Date.current)
    balance_query.balance_cents_as_of(as_of)
  end

  def current_balance_cents
    balance_cents(as_of: Date.current)
  end

  def balance_as_of(date = Date.current)
    balance_query.balance_as_of(date)
  end

  def current_balance
    balance_as_of(Date.current)
  end

  def accounting_user
    rentable_unit&.property&.user
  end

  private

    def balance_query
      Tenancies::BalanceQuery.new(tenancy: self)
    end

    def rentable_unit_is_active
      return unless rentable_unit

      unless rentable_unit.active?
        errors.add(:rentable_unit, "is deactivated and cannot receive new tenancies")
      end
    end

    def termination_date_after_commencement_date
      comm_date = commencement_date
      term_date = termination_date
      return unless comm_date && term_date

      if term_date < comm_date
        errors.add(:termination_date, "must be on or after commencement date")
      end
    end

    def fixed_term_requires_termination_date
      return unless fixed_term?

      if termination_date.blank?
        errors.add(:termination_date, "is required for fixed-term agreement")
      end
    end

    def no_overlapping_tenancies_on_same_unit
      return unless rentable_unit_id && commencement_date

      overlapping = Tenancy.where(rentable_unit_id: rentable_unit_id)
      overlapping = overlapping.where.not(id: id) if persisted?

      start_date = commencement_date
      end_date = termination_date

      overlap_scope = if end_date.present?
        overlapping.where(
          "(commencement_date <= :end_date AND (termination_date IS NULL OR termination_date >= :start_date))",
          start_date: start_date, end_date: end_date
        )
      else
        overlapping.where(
          "(termination_date IS NULL OR termination_date >= :start_date)",
          start_date: start_date
        )
      end

      if overlap_scope.exists?
        errors.add(:base, "An active tenancy already exists for this unit during the specified dates")
      end
    end
end
