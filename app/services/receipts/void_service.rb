module Receipts
  class VoidService
    def self.call(receipt:, reason: nil)
      new(receipt: receipt, reason: reason).call
    end

    def initialize(receipt:, reason: nil)
      @receipt = receipt
      @reason = reason
    end

    def call
      unless receipt.is_a?(Receipt) && receipt.persisted? && !receipt.destroyed?
        return ServiceResult.failure(error: "Receipt must be a persisted Receipt record", code: :invalid_source)
      end

      journal_entry = receipt.journal_entries.find_by(event_type: "receipt_posted")
      unless journal_entry
        return ServiceResult.failure(error: "Journal entry not found for receipt", code: :not_found)
      end

      reversal_entry = nil # : JournalEntry?
      failure_result = nil # : Dry::Monads::Result::Failure?

      Receipt.transaction do
        receipt.lock!

        if receipt.superseded?
          failure_result = ServiceResult.failure(
            error: "Cannot void an already superseded receipt",
            code: :already_superseded
          )
          raise ActiveRecord::Rollback
        end

        if receipt.voided?
          # Idempotent return of existing reversal
          existing_reversal = journal_entry.reversal
          reversal_entry = existing_reversal || journal_entry
          next
        end

        description = reason.presence || "Void receipt ##{receipt.id} - #{receipt.payment_method}"

        reverse_result = Accounting::ReverseEntryService.call(
          journal_entry: journal_entry,
          occurred_on: receipt.received_on,
          description: description
        )

        unless reverse_result.success?
          failure_result = reverse_result
          raise ActiveRecord::Rollback
        end

        reversal_entry = reverse_result.value!.data[:journal_entry]
        receipt.update_columns(voided_at: Time.current)
      end

      if (f = failure_result)
        f
      elsif reversal_entry
        ServiceResult.success(receipt: receipt, journal_entry: reversal_entry)
      else
        ServiceResult.failure(error: "Failed to void receipt", code: :void_failed)
      end
    end

    private

      attr_reader :receipt, :reason
  end
end
