class SecurityDepositTransaction < ApplicationRecord
  KINDS = %w[received refunded applied].freeze

  enum :transaction_kind, {
    received: "received",
    refunded: "refunded",
    applied: "applied"
  }, validate: true

  belongs_to :security_deposit
  belongs_to :party, optional: true
  belongs_to :charge, optional: true
  belongs_to :superseded_by, class_name: "SecurityDepositTransaction", optional: true
  has_one :superseded_transaction, class_name: "SecurityDepositTransaction", foreign_key: :superseded_by_id, dependent: :nullify

  has_many :journal_entries, as: :source, dependent: :restrict_with_error
  has_many :postings, through: :journal_entries

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :occurred_on, presence: true
  validate :validate_occurred_on_not_in_future
  validate :validate_kind_requirements
  validate :validate_ownership_and_tenancy
  validate :prevent_direct_lifecycle_assignment
  validate :validate_immutability_when_posted, on: :update

  before_destroy :prevent_destroy_if_posted

  scope :active, -> { where(voided_at: nil) }
  scope :posted, -> { where.not(posted_at: nil) }
  scope :voided, -> { where.not(voided_at: nil) }
  scope :superseded, -> { where.not(superseded_by_id: nil) }

  def amount
    amount_cents ? (amount_cents / 100.0) : 0.0
  end

  def amount=(val)
    if val.nil? || (val.is_a?(String) && val.blank?)
      write_attribute(:amount_cents, nil)
      return
    end

    str = val.is_a?(Numeric) ? val.to_s : val.to_s.strip
    if str.match?(/\A\d+(\.\d{1,2})?\z/)
      self.amount_cents = (BigDecimal(str) * 100).round
    else
      self.amount_cents = -1
    end
  end

  def posted?
    posted_at.present?
  end

  def voided?
    voided_at.present?
  end

  def superseded?
    superseded_by_id.present?
  end

  def active?
    posted? && !voided?
  end

  def tenancy
    security_deposit&.tenancy
  end

  def property
    tenancy&.property
  end

  def rentable_unit
    tenancy&.rentable_unit
  end

  def accounting_user
    security_deposit&.accounting_user
  end

  private

    def validate_occurred_on_not_in_future
      return unless occurred_on

      if occurred_on > Date.current
        errors.add(:occurred_on, "cannot be in the future")
      end
    end

    def validate_kind_requirements
      case transaction_kind
      when "received"
        errors.add(:party, "is required for received deposit") if party_id.blank?
        errors.add(:charge, "must be blank for received deposit") if charge_id.present?
      when "refunded"
        errors.add(:party, "is required for deposit refund") if party_id.blank?
        errors.add(:charge, "must be blank for deposit refund") if charge_id.present?
      when "applied"
        errors.add(:charge, "is required for deposit application") if charge_id.blank?
        errors.add(:party, "must be blank for deposit application") if party_id.present?
      end
    end

    def validate_ownership_and_tenancy
      return unless security_deposit

      p = party
      if p && p.user_id != security_deposit.accounting_user&.id
        errors.add(:party, "must belong to your account")
      end

      c = charge
      if c
        if c.tenancy_id != security_deposit.tenancy_id
          errors.add(:charge, "must belong to the same tenancy as the security deposit")
        end
        if c.tenancy&.accounting_user != security_deposit.accounting_user
          errors.add(:charge, "must belong to your account")
        end
        if applied? && occurred_on.present? && c.charge_date.present? && occurred_on < c.charge_date
          errors.add(:occurred_on, "cannot precede the charge being settled (#{c.charge_date})")
        end
      end
    end

    def prevent_direct_lifecycle_assignment
      if new_record?
        if posted_at.present?
          errors.add(:posted_at, "cannot be modified directly; posting is managed by the accounting service")
        end
        if voided_at.present?
          errors.add(:voided_at, "cannot be modified directly; use SecurityDepositTransactions::VoidService or SecurityDepositTransactions::CorrectService")
        end
        if superseded_by_id.present?
          errors.add(:superseded_by_id, "cannot be modified directly; use SecurityDepositTransactions::CorrectService")
        end
      else
        if will_save_change_to_voided_at?
          errors.add(:voided_at, "cannot be modified directly; use SecurityDepositTransactions::VoidService or SecurityDepositTransactions::CorrectService")
        end
        if will_save_change_to_superseded_by_id?
          errors.add(:superseded_by_id, "cannot be modified directly; use SecurityDepositTransactions::CorrectService")
        end
        if will_save_change_to_posted_at?
          errors.add(:posted_at, "cannot be modified directly; posting is managed by the accounting service")
        end
      end
    end

    def validate_immutability_when_posted
      return unless posted_at_was.present?

      immutable_fields = %w[
        security_deposit_id transaction_kind amount_cents occurred_on
        party_id charge_id external_reference memo
      ]

      immutable_fields.each do |field|
        if will_save_change_to_attribute?(field)
          errors.add(field.to_sym, "cannot be changed after transaction is posted")
        end
      end
    end

    def prevent_destroy_if_posted
      if posted?
        errors.add(:base, "Posted transactions cannot be deleted")
        throw :abort
      end
    end
end
