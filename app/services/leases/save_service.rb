module Leases
  class SaveService
    SYNC_ATTRIBUTES = %w[
      commencement_date
      termination_date
      annual_rental_amount
      lease_type
    ].freeze

    def self.call(lease:, sync_scheduled_rents: nil, previously_new_record: false)
      new(lease:, sync_scheduled_rents:, previously_new_record:).call
    end

    def initialize(lease:, sync_scheduled_rents: nil, previously_new_record: false)
      @lease = lease
      @sync_scheduled_rents = sync_scheduled_rents
      @previously_new_record = previously_new_record
    end

    def call
      Lease.transaction do
        should_sync = sync_scheduled_rents.nil? ? scheduled_rent_sync_needed? : sync_scheduled_rents
        lease.save!
        Leases::ScheduledRentSyncService.call(lease, previously_new_record:) if should_sync
      end
      ServiceResult.new(success: true, data: lease, error: nil, code: nil)
    rescue ActiveRecord::RecordInvalid
      ServiceResult.new(success: false, data: lease, error: lease.errors.full_messages.to_sentence, code: :validation_error)
    end

    private

    attr_reader :lease, :sync_scheduled_rents, :previously_new_record

    def scheduled_rent_sync_needed?
      SYNC_ATTRIBUTES.any? { |attribute| lease.public_send(:"will_save_change_to_#{attribute}?") }
    end
  end
end
