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
      sync_end_date = end_date
      return unless sync_end_date

      (first_due_date.year..sync_end_date.year).each do |year|
        ScheduledRentsGenerator.new(@lease, year, end_date: sync_end_date).call
      end
    end

    private
      def first_due_date
        if @lease.commencement_date.day == 1
          @lease.commencement_date
        else
          (@lease.commencement_date + 1.month).beginning_of_month
        end
      end

      def end_date
        @end_date ||= if @lease.term?
          @lease.termination_date
        elsif @previously_new_record
          first_due_date + 11.months
        else
          [ first_due_date + 11.months, Date.current + 12.months ].max
        end
      end
  end
end
