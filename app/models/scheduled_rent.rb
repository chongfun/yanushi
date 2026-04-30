class ScheduledRent < ApplicationRecord
  belongs_to :lease
  has_one :rent_payment, dependent: :destroy

  def paid?
    rent_payment.present?
  end

  def late?
    !paid? && Date.current > (due_date + lease.late_period_days.days)
  end

  def display_name
    "#{lease.rental_property.address} - #{due_date}"
  end
end
