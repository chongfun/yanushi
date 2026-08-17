class SecurityDeposit < ApplicationRecord
  belongs_to :tenancy

  has_many :transactions,
    class_name: "SecurityDepositTransaction",
    dependent: :restrict_with_error

  has_many :journal_entries, as: :source, dependent: :restrict_with_error
  has_many :postings, through: :journal_entries

  validates :required_amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :due_on, presence: true
  validates :tenancy_id, uniqueness: true

  validate :validate_requirement_immutability, on: :update

  def required_amount
    required_amount_cents ? (required_amount_cents / 100.0) : 0.0
  end

  def required_amount=(val)
    if val.nil? || (val.is_a?(String) && val.blank?)
      write_attribute(:required_amount_cents, nil)
      return
    end

    str = val.is_a?(Numeric) ? val.to_s : val.to_s.strip
    if str.match?(/\A\d+(\.\d{1,2})?\z/)
      self.required_amount_cents = (BigDecimal(str) * 100).round
    else
      self.required_amount_cents = -1
    end
  end

  def accounting_user
    tenancy&.accounting_user
  end

  def property
    tenancy&.property
  end

  def rentable_unit
    tenancy&.rentable_unit
  end

  def held_cents(as_of: Date.current)
    Accounting::SecurityDepositBalanceQuery.call(tenancy: tenancy, as_of: as_of)
  end

  def held_amount(as_of: Date.current)
    held_cents(as_of: as_of) / 100.0
  end

  def remaining_required_cents(as_of: Date.current)
    [ required_amount_cents - held_cents(as_of: as_of), 0 ].max
  end

  def remaining_required_amount(as_of: Date.current)
    remaining_required_cents(as_of: as_of) / 100.0
  end

  def fully_funded?(as_of: Date.current)
    held_cents(as_of: as_of) >= required_amount_cents
  end

  def overfunded?(as_of: Date.current)
    held_cents(as_of: as_of) > required_amount_cents
  end

  def funding_status(as_of: Date.current)
    held = held_cents(as_of: as_of)
    if held == 0
      "not_funded"
    elsif held < required_amount_cents
      "partially_funded"
    elsif held == required_amount_cents
      "funded"
    else
      "overfunded"
    end
  end

  private

    def validate_requirement_immutability
      if transactions.exists?
        if required_amount_cents_changed?
          errors.add(:required_amount_cents, "cannot be changed after deposit transactions exist")
        end
        if due_on_changed?
          errors.add(:due_on, "cannot be changed after deposit transactions exist")
        end
        if tenancy_id_changed?
          errors.add(:tenancy_id, "cannot be changed after deposit transactions exist")
        end
      end
    end
end
