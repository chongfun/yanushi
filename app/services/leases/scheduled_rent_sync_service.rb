module Leases
  class ScheduledRentSyncService
    def self.call(lease, previously_new_record: false)
      new(lease, previously_new_record: previously_new_record).call
    end

    def initialize(lease, previously_new_record: false)
      @lease = lease
      @previously_new_record = previously_new_record
    end

    def call
      sync_start_date = first_due_date
      sync_end_date = end_date
      return unless sync_start_date && sync_end_date

      (sync_start_date.year..sync_end_date.year).each do |year|
        ScheduledRentsGenerator.new(@lease, year, end_date: sync_end_date).call
      end
    end

    private
      def first_due_date
        starts_on = @lease.commencement_date
        return unless starts_on

        if starts_on.day == 1
          starts_on
        else
          (starts_on + 1.month).beginning_of_month
        end
      end

      def end_date
        @end_date ||= if @lease.term?
          @lease.termination_date
        elsif @previously_new_record
          first_due = first_due_date
          first_due + 11.months if first_due
        else
          first_due = first_due_date
          first_due ? [ first_due + 11.months, Date.current + 12.months ].max : nil
        end
      end
  end
end
