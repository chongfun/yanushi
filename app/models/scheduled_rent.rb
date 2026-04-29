class ScheduledRent < ApplicationRecord
  belongs_to :lease
  has_one :rent_payment, dependent: :destroy

  def paid?
    rent_payment.present?
  end

  def late?
    !paid? && Date.current > (expected_due_date + lease.late_period_days.days)
  end

  def display_name
    "#{lease.rental_property.address} - #{expected_due_date}"
  end
end
