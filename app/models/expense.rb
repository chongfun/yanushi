class Expense < ApplicationRecord
  EXPENSE_KINDS = %w[
    advertising
    auto_and_travel
    cleaning_and_maintenance
    commissions
    insurance
    legal_and_professional
    management
    mortgage_interest
    other_interest
    repairs
    supplies
    taxes
    utilities
    other
  ].freeze

  IMMUTABLE_POSTED_ATTRIBUTES = %w[
    property_id
    rentable_unit_id
    expense_kind
    amount_cents
    paid_on
    vendor_name
    external_reference
    description
  ].freeze

  belongs_to :property
  belongs_to :rentable_unit, optional: true
  belongs_to :superseded_by, class_name: "Expense", optional: true

  has_one :superseded_expense, class_name: "Expense", foreign_key: :superseded_by_id
  has_many :journal_entries, as: :source, dependent: :restrict_with_error
  has_many :charges, foreign_key: :source_expense_id, dependent: :restrict_with_error
  has_many :reimbursement_charges, -> { where(charge_kind: "reimbursement") }, class_name: "Charge", foreign_key: :source_expense_id, dependent: :restrict_with_error

  enum :expense_kind, EXPENSE_KINDS.index_by(&:itself), prefix: false, validate: true

  validates :property, presence: true
  validates :expense_kind, presence: true
  validates :amount_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :paid_on, presence: true

  validate :validate_rentable_unit_property_consistency
  validate :validate_superseded_by_same_user
  validate :prevent_mutation_after_posting, on: :update
  before_destroy :prevent_destroy_if_posted

  scope :active, -> { where(voided_at: nil) }
  scope :voided, -> { where.not(voided_at: nil) }
  scope :posted, -> { where.not(posted_at: nil) }

  attr_accessor :raw_amount

  def amount
    return nil if amount_cents.nil? || amount_cents.zero?

    BigDecimal(amount_cents.to_s) / 100
  end

  def amount=(val)
    @raw_amount = val.presence
    if val.present? && val.to_s.strip.present?
      begin
        self.amount_cents = (BigDecimal(val.to_s) * 100).round
      rescue StandardError
        self.amount_cents = nil
      end
    else
      self.amount_cents = nil
    end
  end

  def formatted_amount
    return @raw_amount if defined?(@raw_amount) && @raw_amount.present?
    return nil if amount.nil?

    sprintf("%.2f", amount)
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

  def superseded?
    superseded_by_id.present?
  end

  def lifecycle_status
    if superseded?
      :superseded
    elsif voided?
      :voided
    elsif posted?
      :posted
    else
      :draft
    end
  end

  def total_active_reimbursement_cents
    reimbursement_charges.active.sum(:amount_cents)
  end

  def remaining_reimbursable_cents
    [ amount_cents.to_i - total_active_reimbursement_cents, 0 ].max
  end

  def remaining_reimbursable_amount
    BigDecimal(remaining_reimbursable_cents.to_s) / 100
  end

  def reimbursed?
    reimbursement_charges.exists?
  end

  def fully_reimbursed?
    reimbursed? && remaining_reimbursable_cents <= 0
  end

  def accounting_user
    property&.user
  end

  private

    def validate_rentable_unit_property_consistency
      return unless property_id.present?
      return unless (unit = rentable_unit)

      if unit.property_id != property_id
        errors.add(:rentable_unit, "must belong to the selected property")
      end
    end

    def validate_superseded_by_same_user
      return unless (superseded = superseded_by)

      if superseded.accounting_user != accounting_user
        errors.add(:superseded_by, "must belong to the same user")
      end
    end

    def prevent_mutation_after_posting
      if will_save_change_to_attribute?(:voided_at)
        errors.add(:voided_at, "cannot be modified directly; use Expenses::VoidService")
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
          errors.add(attr.to_sym, "cannot be modified after expense is posted")
        end
      end
    end

    def prevent_destroy_if_posted
      if posted? || journal_entries.exists?
        errors.add(:base, "Cannot delete a posted expense. Void the expense instead.")
        throw(:abort)
      end
    end
end
