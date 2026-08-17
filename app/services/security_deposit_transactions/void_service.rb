module SecurityDepositTransactions
  class VoidService
    def self.call(transaction:, reason: nil)
      new(transaction: transaction, reason: reason).call
    end

    def initialize(transaction:, reason: nil)
      @transaction = transaction
      @reason = reason
    end

    def call
      unless transaction.is_a?(SecurityDepositTransaction) && transaction.persisted? && !transaction.destroyed?
        return ServiceResult.failure(error: "Transaction must be a persisted SecurityDepositTransaction record", code: :invalid_source)
      end

      deposit = transaction.security_deposit
      unless deposit
        return ServiceResult.failure(error: "Security deposit not found", code: :not_found)
      end

      entry_event = "deposit_#{transaction.transaction_kind}"
      journal_entry = transaction.journal_entries.find_by(event_type: entry_event)
      unless journal_entry
        return ServiceResult.failure(error: "Journal entry not found for deposit transaction", code: :not_found)
      end

      reversal_entry = nil # : JournalEntry?
      failure_result = nil # : (Dry::Monads::Result::Success | Dry::Monads::Result::Failure)?
      success_result = nil # : (Dry::Monads::Result::Success | Dry::Monads::Result::Failure)?

      SecurityDeposit.transaction do
        deposit.lock!
        transaction.lock!

        if transaction.superseded?
          failure_result = ServiceResult.failure(
            error: "Cannot void an already superseded deposit transaction",
            code: :already_superseded
          )
          raise ActiveRecord::Rollback
        end

        description = reason.presence || "Void deposit transaction ##{transaction.id}: #{transaction.transaction_kind}"

        if transaction.voided?
          existing_reversal = journal_entry.reversal
          if existing_reversal &&
             existing_reversal.occurred_on == transaction.occurred_on &&
             existing_reversal.description.to_s.strip == description.to_s.strip
            success_result = ServiceResult.success(transaction: transaction, journal_entry: existing_reversal)
          else
            failure_result = ServiceResult.failure(
              error: "Cannot void an already voided transaction with different parameters",
              code: :idempotency_conflict
            )
          end
          raise ActiveRecord::Rollback
        end

        timeline_res = SecurityDeposits::LiabilityTimeline.validate(
          security_deposit: deposit,
          removing_ids: [ transaction.id ]
        )
        unless timeline_res.success?
          failure_result = timeline_res
          raise ActiveRecord::Rollback
        end

        reverse_result = Accounting::ReverseEntryService.call(
          journal_entry: journal_entry,
          occurred_on: transaction.occurred_on,
          description: description
        )

        unless reverse_result.success?
          failure_result = reverse_result
          raise ActiveRecord::Rollback
        end

        reversal_entry = reverse_result.value!.data[:journal_entry]
        transaction.update_columns(voided_at: Time.current)
      end

      if (s = success_result)
        s
      elsif (f = failure_result)
        f
      elsif (r = reversal_entry)
        ServiceResult.success(transaction: transaction, journal_entry: r)
      else
        ServiceResult.failure(error: "Failed to void deposit transaction", code: :void_failed)
      end
    end

    private

      attr_reader :transaction, :reason
  end
end
