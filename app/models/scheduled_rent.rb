class ScheduledRent < ApplicationRecord
  belongs_to :lease

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :due_date, presence: true

  def covered?(as_of: Date.current)
    covered_through = due_date
    return false unless covered_through

    lease.total_credits(as_of: as_of) >= lease.total_debits(as_of: covered_through)
  end

  def late?(as_of: Date.current)
    due_on = due_date
    grace_days = lease.late_period_days
    return false unless due_on && grace_days

    !covered?(as_of: as_of) && as_of > (due_on + grace_days.days)
  end

  def display_name
    "#{lease.rental_property.address} - #{due_date}"
  end
end
