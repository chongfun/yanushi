module Charges
  class VoidService
    def self.call(charge:, occurred_on: nil, reason: nil)
      new(charge: charge, occurred_on: occurred_on, reason: reason).call
    end

    def initialize(charge:, occurred_on: nil, reason: nil)
      @charge = charge
      @occurred_on = occurred_on || Date.current
      @reason = reason
    end

    def call
      unless charge.is_a?(Charge) && charge.persisted? && !charge.destroyed?
        return ServiceResult.failure(error: "Charge must be a persisted Charge record", code: :invalid_source)
      end

      journal_entry = charge.journal_entries.find_by(event_type: "charge_posted")
      unless journal_entry
        return ServiceResult.failure(error: "Journal entry not found for charge", code: :not_found)
      end

      reversal_entry = nil # : JournalEntry?
      failure_result = nil # : Dry::Monads::Result::Failure?

      Charge.transaction do
        charge.lock!

        description = reason.presence || "Void charge ##{charge.id}: #{charge.description || charge.charge_kind}"
        # Ensure occurred_on is at least the original charge occurred_on
        effective_occurred_on = [ occurred_on, journal_entry.occurred_on ].max

        reverse_result = Accounting::ReverseEntryService.call(
          journal_entry: journal_entry,
          occurred_on: effective_occurred_on,
          description: description
        )

        unless reverse_result.success?
          failure_result = reverse_result
          raise ActiveRecord::Rollback
        end

        reversal_entry = reverse_result.value!.data[:journal_entry]
        charge.update_columns(voided_at: Time.current)
      end

      if (f = failure_result)
        f
      elsif reversal_entry
        ServiceResult.success(charge: charge, journal_entry: reversal_entry)
      else
        ServiceResult.failure(error: "Failed to void charge", code: :void_failed)
      end
    end

    private

      attr_reader :charge, :occurred_on, :reason
  end
end
