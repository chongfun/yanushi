class ScheduledRent < ShardedRecord
  belongs_to :lease

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :due_date, presence: true

  def covered?(as_of: Date.current)
    lease.total_credits(as_of: as_of) >= lease.total_debits(as_of: due_date)
  end

  def late?(as_of: Date.current)
    !covered?(as_of: as_of) && as_of > (due_date + lease.late_period_days.days)
  end

  def display_name
    "#{lease.rental_property.address} - #{due_date}"
  end
end
