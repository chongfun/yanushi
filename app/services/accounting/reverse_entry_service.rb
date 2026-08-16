module Accounting
  class ReverseEntryService
    def self.call(journal_entry:, occurred_on:, description: nil)
      new(
        journal_entry: journal_entry,
        occurred_on: occurred_on,
        description: description
      ).call
    end

    def initialize(journal_entry:, occurred_on:, description: nil)
      @journal_entry = journal_entry
      @raw_occurred_on = occurred_on
      @description = description
    end

    def call
      unless journal_entry.is_a?(JournalEntry) && journal_entry.persisted? && !journal_entry.destroyed?
        return ServiceResult.failure(
          error: "Journal entry must be a persisted record",
          code: :invalid_source
        )
      end

      occurred_on = parse_date(raw_occurred_on)
      unless occurred_on
        return ServiceResult.failure(
          error: "Occurred on must be a valid date",
          code: :invalid_input
        )
      end

      if journal_entry.reversal?
        return ServiceResult.failure(
          error: "Cannot reverse a reversal journal entry",
          code: :invalid_reversal
        )
      end

      if occurred_on < journal_entry.occurred_on
        return ServiceResult.failure(
          error: "Reversal occurred_on cannot precede original entry date",
          code: :invalid_date
        )
      end

      resolved_desc = description.presence || "Reversal of entry #{journal_entry.id}"

      begin
        reversal = nil

        JournalEntry.transaction do
          journal_entry.lock!

          existing_reversal = journal_entry.reversal
          if existing_reversal
            return verify_idempotency(existing_reversal, occurred_on, resolved_desc)
          end

          user = journal_entry.user

          reversal = user.journal_entries.create!(
            source_type: "JournalEntry",
            source_id: journal_entry.id,
            event_type: "reversal",
            occurred_on: occurred_on,
            description: resolved_desc,
            reversal_of_id: journal_entry.id,
            posted_at: Time.current
          )

          journal_entry.postings.find_each do |original_posting|
            reversal.postings.create!(
              account_id: original_posting.account_id,
              amount_cents: -original_posting.amount_cents,
              property_id: original_posting.property_id,
              rentable_unit_id: original_posting.rentable_unit_id,
              tenancy_id: original_posting.tenancy_id,
              party_id: original_posting.party_id,
              memo: original_posting.memo
            )
          end
        end

        ServiceResult.success(journal_entry: reversal)
      rescue ActiveRecord::RecordNotUnique
        existing = journal_entry.reload.reversal
        if existing
          verify_idempotency(existing, occurred_on, resolved_desc)
        else
          ServiceResult.failure(error: "Reversal conflict occurred", code: :idempotency_conflict)
        end
      rescue ActiveRecord::RecordInvalid => e
        ServiceResult.failure(error: e.record.errors.full_messages.to_sentence, code: :validation_error)
      end
    end

    private

      attr_reader :journal_entry, :raw_occurred_on, :description

      def parse_date(val)
        return nil if val.blank?
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s)
      rescue ArgumentError, Date::Error
        nil
      end

      def verify_idempotency(existing, resolved_occurred_on, resolved_desc)
        if existing.occurred_on == resolved_occurred_on && existing.description.to_s.strip == resolved_desc.strip
          ServiceResult.success(journal_entry: existing)
        else
          ServiceResult.failure(
            error: "Reversal already exists with different details",
            code: :idempotency_conflict,
            data: { journal_entry: existing }
          )
        end
      end
  end
end
