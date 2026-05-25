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

  after_create :generate_scheduled_rents
  after_update :generate_scheduled_rents,
    if: -> { saved_change_to_commencement_date? || saved_change_to_termination_date? ||
             saved_change_to_annual_rental_amount? || saved_change_to_lease_type? }

  # Total credits (payments received) up to a given date
  def total_credits(as_of: Date.current)
    tenant_payments.where("payment_date <= ?", as_of).sum(:amount)
  end

  # Total debits (rents + charges) up to a given date
  def total_debits(as_of: Date.current)
    rent_debits = scheduled_rents.where("due_date <= ?", as_of).sum(:amount)
    charge_debits = tenant_charges.where("charge_date <= ?", as_of).sum(:amount)
    rent_debits + charge_debits
  end

  # Positive = tenant has credit, negative = tenant owes money
  def balance_as_of(date = Date.current)
    total_credits(as_of: date) - total_debits(as_of: date)
  end

  def current_balance
    balance_as_of(Date.current)
  end

  private

  def generate_scheduled_rents
    first_due_date = if commencement_date.day == 1
      commencement_date
    else
      (commencement_date + 1.month).beginning_of_month
    end

    end_date = if term?
      termination_date
    else
      if previously_new_record?
        first_due_date + 11.months
      else
        [ first_due_date + 11.months, Date.current + 12.months ].max
      end
    end

    return unless end_date

    # Use first_due_date's year to ensure we generate from the starting year
    (first_due_date.year..end_date.year).each do |year|
      ScheduledRentsGenerator.new(self, year, end_date: end_date).call
    end
  end
end
