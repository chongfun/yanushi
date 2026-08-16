class Charge < ApplicationRecord
  CHARGE_KINDS = %w[
    rent
    late_fee
    reimbursement
    other
  ].freeze

  IMMUTABLE_POSTED_ATTRIBUTES = %w[
    tenancy_id
    charge_kind
    amount_cents
    charge_date
    due_on
    description
    rent_term_id
    source_expense_id
    service_period_start
    service_period_end
  ].freeze

  belongs_to :tenancy
  belongs_to :rent_term, optional: true
  belongs_to :source_expense, class_name: "Expense", optional: true
  belongs_to :superseded_by, class_name: "Charge", optional: true

  has_one :superseded_charge, class_name: "Charge", foreign_key: :superseded_by_id
  has_many :journal_entries, as: :source, dependent: :restrict_with_error

  enum :charge_kind, CHARGE_KINDS.index_by(&:itself), prefix: false, validate: true

  validates :amount_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :charge_kind, presence: true
  validates :charge_date, presence: true
  validates :due_on, presence: true

  validate :validate_service_period_range
  validate :validate_kind_specific_invariants
  validate :validate_ownership_consistency
  validate :prevent_mutation_after_posting, on: :update
  before_destroy :prevent_destroy_if_posted

  scope :active, -> { where(voided_at: nil) }
  scope :voided, -> { where.not(voided_at: nil) }
  scope :posted, -> { where.not(posted_at: nil) }

  def amount
    amount_cents ? (BigDecimal(amount_cents) / 100) : nil
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

  def posted?
    posted_at.present?
  end

  def voided?
    voided_at.present?
  end

  def active?
    voided_at.nil?
  end

  def accounting_user
    tenancy&.accounting_user
  end

  private

    def validate_service_period_range
      start_date = service_period_start
      end_date = service_period_end
      return unless start_date && end_date

      if end_date < start_date
        errors.add(:service_period_end, "cannot be before service period start")
      end
    end

    def validate_kind_specific_invariants
      case charge_kind
      when "rent"
        validate_rent_invariants
      when "reimbursement"
        validate_reimbursement_invariants
      when "late_fee"
        validate_late_fee_invariants
      when "other"
        validate_other_invariants
      end
    end

    def validate_rent_invariants
      errors.add(:rent_term, "is required for rent charge") if rent_term_id.nil?
      errors.add(:service_period_start, "is required for rent charge") if service_period_start.nil?
      errors.add(:service_period_end, "is required for rent charge") if service_period_end.nil?
      errors.add(:source_expense, "must be blank for rent charge") if source_expense_id.present?

      term = rent_term
      t = tenancy
      return unless term && t

      if term.tenancy_id != tenancy_id
        errors.add(:rent_term, "must belong to the same tenancy")
      end

      validate_rent_service_period_bounds(term, t)
    end

    def validate_rent_service_period_bounds(term, t)
      start_date = service_period_start
      end_date = service_period_end
      return unless start_date && end_date

      t_commencement = t.commencement_date
      if t_commencement && start_date < t_commencement
        errors.add(:service_period_start, "cannot be before tenancy commencement date")
      end

      t_termination = t.termination_date
      if t_termination && end_date > t_termination
        errors.add(:service_period_end, "cannot be after tenancy termination date")
      end

      term_from = term.effective_from
      if term_from && start_date < term_from
        errors.add(:service_period_start, "cannot be before rent term effective from date")
      end

      term_until = term.effective_until
      if term_until && end_date > term_until
        errors.add(:service_period_end, "cannot be after rent term effective until date")
      end
    end

    def validate_reimbursement_invariants
      errors.add(:source_expense, "is required for reimbursement charge") if source_expense_id.nil?
      errors.add(:rent_term, "must be blank for reimbursement charge") if rent_term_id.present?
      errors.add(:service_period_start, "must be blank for reimbursement charge") if service_period_start.present?
      errors.add(:service_period_end, "must be blank for reimbursement charge") if service_period_end.present?

      exp = source_expense
      t = tenancy
      return unless exp && t

      if exp.property_id != t.property&.id
        errors.add(:source_expense, "must belong to the same property as the tenancy")
      end
    end

    def validate_late_fee_invariants
      errors.add(:rent_term, "must be blank for late fee charge") if rent_term_id.present?
      errors.add(:source_expense, "must be blank for late fee charge") if source_expense_id.present?
    end

    def validate_other_invariants
      errors.add(:rent_term, "must be blank for other charge") if rent_term_id.present?
      errors.add(:source_expense, "must be blank for other charge") if source_expense_id.present?
    end

    def validate_ownership_consistency
      exp = source_expense
      t = tenancy
      return unless exp && t

      if exp.accounting_user != t.accounting_user
        errors.add(:source_expense, "must belong to the same user as the tenancy")
      end
    end

    def prevent_mutation_after_posting
      if will_save_change_to_attribute?(:voided_at)
        errors.add(:voided_at, "cannot be modified directly; use Charges::VoidService")
      end

      return unless posted_at_was.present?

      if will_save_change_to_attribute?(:posted_at)
        errors.add(:posted_at, "cannot be modified once posted")
      end

      if will_save_change_to_attribute?(:superseded_by_id)
        errors.add(:superseded_by_id, "cannot be modified directly")
      end

      IMMUTABLE_POSTED_ATTRIBUTES.each do |attr|
        if will_save_change_to_attribute?(attr)
          errors.add(attr.to_sym, "cannot be modified after charge is posted")
        end
      end
    end

    def prevent_destroy_if_posted
      if posted? || journal_entries.exists?
        errors.add(:base, "Cannot delete a posted charge. Void the charge instead.")
        throw(:abort)
      end
    end
end
