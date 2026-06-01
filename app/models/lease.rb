class Lease < ApplicationRecord
  belongs_to :rental_property
  has_many :lease_tenants, dependent: :destroy
  has_many :tenants, through: :lease_tenants
  has_many :scheduled_rents, dependent: :destroy
  has_many :tenant_payments, dependent: :destroy
  has_many :tenant_charges, dependent: :destroy

  enum :lease_type, { month_to_month: 0, term: 1 }

  validates :commencement_date, presence: true
  validates :annual_rental_amount, presence: true, numericality: { greater_than: 0 }
  validates :lease_type, presence: true

  # Total credits (payments received) up to a given date
  def total_credits(as_of: Date.current)
    balance_query.total_credits(as_of: as_of)
  end

  def total_debits(as_of: Date.current)
    balance_query.total_debits(as_of: as_of)
  end

  # Positive = tenant has credit, negative = tenant owes money
  def balance_as_of(date = Date.current)
    balance_query.balance_as_of(date)
  end

  def current_balance
    balance_as_of(Date.current)
  end

  scope :active, ->(date = Date.current) {
    where("commencement_date <= ?", date)
      .where("termination_date IS NULL OR termination_date >= ?", date)
  }

  def active?(date = Date.current)
    starts_on = commencement_date
    ends_on = termination_date
    return false unless starts_on

    starts_on <= date && (ends_on.nil? || ends_on >= date)
  end

  private

    def balance_query
      Leases::BalanceQuery.new(lease: self)
    end
end
