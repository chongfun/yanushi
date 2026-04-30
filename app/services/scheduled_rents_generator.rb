class ScheduledRentsGenerator
  def initialize(lease, year, end_date: nil)
    @lease = lease
    @year = year.to_i
    @end_date = end_date
  end

  def call
    amount_per_month = @lease.annual_rental_amount / 12.0

    1.upto(12) do |month|
      date = Date.new(@year, month, 1)

      # Skip if before lease start
      next if date < @lease.commencement_date.beginning_of_month

      # Skip if after lease end (for term leases)
      if @lease.term? && @lease.termination_date
        next if date > @lease.termination_date.beginning_of_month
      end

      if @end_date
        next if date > @end_date.beginning_of_month
      end

      # Calculate exact due date by adding the month difference
      # between the target month/year and the commencement month/year
      months_diff = (@year * 12 + month) - (@lease.commencement_date.year * 12 + @lease.commencement_date.month)
      due_date = @lease.commencement_date + months_diff.months

      # Check for existing scheduled rent in this month
      unless @lease.scheduled_rents.where(due_date: due_date.beginning_of_month..due_date.end_of_month).exists?
        @lease.scheduled_rents.create!(
          amount: amount_per_month,
          due_date: due_date
        )
      end
    end
  end
end
