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
    if tenant_payments.loaded?
      tenant_payments.select { |tp| tp.payment_date <= as_of }.sum(&:amount)
    else
      tenant_payments.where("payment_date <= ?", as_of).sum(:amount)
    end
  end

  def total_debits(as_of: Date.current)
    if scheduled_rents.loaded? && tenant_charges.loaded?
      rent_debits = scheduled_rents.select { |sr| sr.due_date <= as_of }.sum(&:amount)
      charge_debits = tenant_charges.select { |tc| tc.charge_date <= as_of }.sum(&:amount)
    else
      rent_debits = scheduled_rents.where("due_date <= ?", as_of).sum(:amount)
      charge_debits = tenant_charges.where("charge_date <= ?", as_of).sum(:amount)
    end
    rent_debits + charge_debits
  end

  # Positive = tenant has credit, negative = tenant owes money
  def balance_as_of(date = Date.current)
    total_credits(as_of: date) - total_debits(as_of: date)
  end

  def current_balance
    balance_as_of(Date.current)
  end

  scope :active, ->(date = Date.current) {
    where("commencement_date <= ?", date)
      .where("termination_date IS NULL OR termination_date >= ?", date)
  }

  def active?(date = Date.current)
    commencement_date <= date && (termination_date.nil? || termination_date >= date)
  end
end
