class ScheduledRent < ApplicationRecord
  belongs_to :lease
  has_many :rent_payments, dependent: :destroy

  def paid?
    paid
  end

  def balance_due
    amount - rent_payments.sum(:amount)
  end

  def partial_payment?
    total_paid = rent_payments.sum(:amount)
    total_paid > 0 && total_paid < amount
  end

  def late?
    !paid? && Date.current > (due_date + lease.late_period_days.days)
  end

  def display_name
    "#{lease.rental_property.address} - #{due_date}"
  end
end
