class Receipt < ApplicationRecord
  belongs_to :user
  belongs_to :tenancy
  belongs_to :payer_party, class_name: "Party"
  belongs_to :superseded_by, class_name: "Receipt", optional: true

  has_one :superseded_receipt, class_name: "Receipt", foreign_key: :superseded_by_id, dependent: :nullify
  has_one :imported_transaction, as: :confirmed_source
  has_many :journal_entries, as: :source, dependent: :restrict_with_error

  normalizes :payment_method, with: ->(m) { m&.strip&.downcase }
  normalizes :external_reference, with: ->(r) { r.presence&.strip }

  validates :user, presence: true
  validates :tenancy, presence: true
  validates :payer_party, presence: true
  validates :received_on, presence: true
  validates :payment_method, presence: true
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :external_reference, uniqueness: {
    scope: %i[user_id payment_method],
    conditions: -> { where(voided_at: nil).where.not(external_reference: nil) },
    allow_nil: true
  }

  validate :user_matches_tenancy_owner
  validate :payer_party_matches_user
  validate :superseded_by_same_user, if: :superseded_by_id?
  validate :validate_amount_format
  validate :prevent_mutation_after_posting, on: :update

  before_destroy :prevent_destroy

  scope :active, -> { where(voided_at: nil) }
  scope :voided, -> { where.not(voided_at: nil) }

  def tenancy=(t)
    super
    self.user ||= t.accounting_user if t.respond_to?(:accounting_user)
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
    !voided?
  end

  def amount
    return nil if amount_cents.nil?

    BigDecimal(amount_cents.to_s) / 100
  end

  def amount=(value)
    if value.blank?
      self.amount_cents = nil
      @amount_error = nil
      return
    end

    val_str = value.is_a?(Numeric) ? value.to_s : value.to_s.strip
    unless val_str =~ /\A-?\d+(\.\d+)?\z/
      @amount_error = "is not a valid number"
      self.amount_cents = nil
      return
    end

    if val_str.include?(".")
      decimals = val_str.split(".").last
      if decimals.length > 2 && decimals[2..].to_i != 0
        @amount_error = "cannot have fractional cents"
        self.amount_cents = nil
        return
      end
    end

    @amount_error = nil
    self.amount_cents = (BigDecimal(val_str) * 100).round
  end

  def accounting_user
    user
  end

  private

    def user_matches_tenancy_owner
      if tenancy.present? && user.present? && tenancy.accounting_user != user
        errors.add(:tenancy, "must belong to the receipt owner")
      end
    end

    def payer_party_matches_user
      if payer_party.present? && user.present? && payer_party.user != user
        errors.add(:payer_party, "must belong to the receipt owner")
      end
    end

    def superseded_by_same_user
      if superseded_by.present? && superseded_by.user_id != user_id
        errors.add(:superseded_by, "must belong to the same user")
      end
    end

    def validate_amount_format
      errors.add(:amount, @amount_error) if @amount_error.present?
    end

    def prevent_mutation_after_posting
      if posted_at_was.present?
        if will_save_change_to_voided_at?
          errors.add(:voided_at, "cannot be modified directly; use Receipts::VoidService or Receipts::CorrectService")
        end
        if will_save_change_to_posted_at?
          errors.add(:posted_at, "cannot be modified directly once posted")
        end
        if will_save_change_to_superseded_by_id?
          errors.add(:superseded_by_id, "cannot be modified directly; use Receipts::CorrectService")
        end

        protected_attrs = %w[user_id tenancy_id payer_party_id amount_cents received_on payment_method external_reference memo]
        if protected_attrs.any? { |attr| will_save_change_to_attribute?(attr) }
          errors.add(:base, "Posted receipts are immutable records")
        end
      end
    end

    def prevent_destroy
      if posted?
        errors.add(:base, "Cannot delete a posted receipt")
        throw(:abort)
      end
    end
end
