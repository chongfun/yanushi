class ScheduledRent < ApplicationRecord
  belongs_to :tenancy

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :due_date, presence: true

  def covered?(as_of: Date.current)
    covered_through = due_date
    return false unless covered_through

    tenancy.total_credits(as_of: as_of) >= tenancy.total_debits(as_of: covered_through)
  end

  def late?(as_of: Date.current)
    due_on = due_date
    grace_days = tenancy.late_period_days
    return false unless due_on && grace_days

    !covered?(as_of: as_of) && as_of > (due_on + grace_days.days)
  end

  def display_name
    "#{tenancy.property&.address} - #{due_date}"
  end
end
