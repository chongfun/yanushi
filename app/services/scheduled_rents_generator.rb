class ScheduledRentsGenerator
  def initialize(lease, year, end_date: nil)
    @lease = lease
    @year = year.to_i
    @end_date = end_date
  end

  def call
    amount = (@lease.annual_rental_amount / 12).truncate(2)
    first_due_date = first_due_date_for(@lease.commencement_date)

    1.upto(12) do |month|
      date = Date.new(@year, month, 1)

      # Skip if before the first due date
      next if date < first_due_date

      # Skip if after lease end (for term leases)
      if @lease.term? && @lease.termination_date
        next if date > @lease.termination_date.beginning_of_month
      end

      if @end_date
        next if date > @end_date.beginning_of_month
      end

      # Check for existing scheduled rent in this month
      unless @lease.scheduled_rents.where(due_date: date.beginning_of_month..date.end_of_month).exists?
        @lease.scheduled_rents.create!(
          amount: amount,
          due_date: date
        )
      end
    end
  end

  private

  def first_due_date_for(date)
    if date.day == 1
      date
    else
      (date + 1.month).beginning_of_month
    end
  end
end
