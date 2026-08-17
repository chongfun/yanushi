module Charges
  class VoidService
    def self.call(charge:, occurred_on: nil, reason: nil)
      new(charge: charge, occurred_on: occurred_on, reason: reason).call
    end

    def initialize(charge:, occurred_on: nil, reason: nil)
      @charge = charge
      @raw_occurred_on = occurred_on
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

      resolved_occurred_on = if @raw_occurred_on.present?
        parsed = parse_date(@raw_occurred_on)
        return ServiceResult.failure(error: "Invalid occurred on date", code: :invalid_input) unless parsed

        parsed
      else
        Date.current
      end

      reversal_entry = nil # : JournalEntry?
      failure_result = nil # : Dry::Monads::Result::Failure?

      source_expense = if charge.reimbursement? && charge.source_expense_id.present?
        Expense.find_by(id: charge.source_expense_id)
      end

      Charge.transaction do
        source_expense&.lock!
        charge.lock!

        if charge.superseded?
          failure_result = ServiceResult.failure(
            error: "Cannot void an already superseded charge",
            code: :already_superseded
          )
          raise ActiveRecord::Rollback
        end

        if charge.security_deposit_applications.active.exists?
          failure_result = ServiceResult.failure(
            error: "Cannot void a charge with active security deposit applications. Void or correct the deposit applications first.",
            code: :active_deposit_applications
          )
          raise ActiveRecord::Rollback
        end

        description = reason.presence || "Void charge ##{charge.id}: #{charge.description || charge.charge_kind}"
        effective_occurred_on = [ resolved_occurred_on, journal_entry.occurred_on ].max

        if charge.voided?
          existing_reversal = journal_entry.reversal
          if existing_reversal &&
             existing_reversal.occurred_on == effective_occurred_on &&
             existing_reversal.description.to_s.strip == description.to_s.strip
            reversal_entry = existing_reversal
            next
          else
            failure_result = ServiceResult.failure(
              error: "Cannot void an already voided charge with different parameters",
              code: :idempotency_conflict
            )
            raise ActiveRecord::Rollback
          end
        end

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

      attr_reader :charge, :raw_occurred_on, :reason

      def parse_date(val)
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s)
      rescue ArgumentError, Date::Error
        nil
      end
  end
end
