module Accounting
  class PostEntryService
    def self.call(source:, event_type:, occurred_on:, postings:, user: nil, description: nil)
      new(
        user: user,
        source: source,
        event_type: event_type,
        occurred_on: occurred_on,
        postings: postings,
        description: description
      ).call
    end

    def initialize(source:, event_type:, occurred_on:, postings:, user: nil, description: nil)
      @user = user
      @source = source
      @event_type = event_type.to_s
      @raw_occurred_on = occurred_on
      @postings = postings
      @description = description
    end

    def call
      unless source.is_a?(ActiveRecord::Base) && source.persisted? && !source.destroyed?
        return ServiceResult.failure(error: "Source must be a persisted ActiveRecord object", code: :invalid_source)
      end

      unless source.respond_to?(:accounting_user)
        return ServiceResult.failure(error: "Source must implement accounting_user", code: :invalid_source)
      end

      source_user = source.public_send(:accounting_user) # : User?
      unless source_user.is_a?(User) && source_user.persisted? && !source_user.destroyed?
        return ServiceResult.failure(error: "Source accounting_user must be a persisted user", code: :invalid_source)
      end

      if (u = user) && u.id != source_user.id
        return ServiceResult.failure(error: "Source does not belong to user", code: :ownership_mismatch)
      end

      target_user = source_user

      if event_type.blank?
        return ServiceResult.failure(error: "Event type is required", code: :invalid_input)
      end

      occurred_on = parse_date(raw_occurred_on)
      unless occurred_on
        return ServiceResult.failure(error: "Occurred on must be a valid date", code: :invalid_input)
      end

      builder_result = PostingBuilder.call(user: target_user, postings: postings)
      return builder_result unless builder_result.success?

      normalized_postings = builder_result.value!.data[:postings]
      source_type = source.class.base_class.name
      source_id = source.id

      # 1. Pre-check existing entry
      existing_entry = JournalEntry.find_by(
        user_id: target_user.id,
        source_type: source_type,
        source_id: source_id,
        event_type: event_type
      )

      if existing_entry
        return verify_idempotency(existing_entry, occurred_on, normalized_postings)
      end

      # 2. Attempt creation in transaction
      created_entry = nil
      begin
        JournalEntry.transaction do
          entry = target_user.journal_entries.create!(
            source_type: source_type,
            source_id: source_id,
            event_type: event_type,
            occurred_on: occurred_on,
            description: description,
            posted_at: Time.current
          )
          created_entry = entry

          normalized_postings.each do |p_attrs|
            entry.postings.create!(
              account_id: p_attrs[:account_id],
              amount_cents: p_attrs[:amount_cents],
              property_id: p_attrs[:property_id],
              rentable_unit_id: p_attrs[:rentable_unit_id],
              tenancy_id: p_attrs[:tenancy_id],
              party_id: p_attrs[:party_id],
              memo: p_attrs[:memo]
            )
          end
        end

        ServiceResult.success(journal_entry: created_entry)
      rescue ActiveRecord::RecordNotUnique
        # Concurrency race: lost insertion race to concurrent process
        existing = JournalEntry.find_by!(
          user_id: target_user.id,
          source_type: source_type,
          source_id: source_id,
          event_type: event_type
        )
        verify_idempotency(existing, occurred_on, normalized_postings)
      rescue ActiveRecord::RecordInvalid => e
        ServiceResult.failure(error: e.record.errors.full_messages.to_sentence, code: :validation_error)
      end
    end

    private

      attr_reader :user, :source, :event_type, :raw_occurred_on, :postings, :description

      def parse_date(val)
        return nil if val.blank?
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s)
      rescue ArgumentError, Date::Error
        nil
      end

      def verify_idempotency(entry, resolved_occurred_on, requested_postings)
        if entry.occurred_on != resolved_occurred_on
          return ServiceResult.failure(
            error: "Posting event already exists with different occurred_on date",
            code: :idempotency_conflict,
            data: { journal_entry: entry }
          )
        end

        if entry.description.to_s.strip != description.to_s.strip
          return ServiceResult.failure(
            error: "Posting event already exists with different description",
            code: :idempotency_conflict,
            data: { journal_entry: entry }
          )
        end

        existing_postings = entry.postings.to_a
        if existing_postings.size != requested_postings.size
          return ServiceResult.failure(
            error: "Posting event already exists with different number of postings",
            code: :idempotency_conflict,
            data: { journal_entry: entry }
          )
        end

        # Canonical sort for comparison
        sort_key = ->(p) {
          [
            p[:account_id],
            p[:amount_cents],
            p[:property_id] || 0,
            p[:rentable_unit_id] || 0,
            p[:tenancy_id] || 0,
            p[:party_id] || 0,
            p[:memo].to_s.strip
          ]
        }

        existing_sorted = existing_postings.map { |p|
          {
            account_id: p.account_id,
            amount_cents: p.amount_cents,
            property_id: p.property_id,
            rentable_unit_id: p.rentable_unit_id,
            tenancy_id: p.tenancy_id,
            party_id: p.party_id,
            memo: p.memo
          }
        }.sort_by(&sort_key)

        requested_sorted = requested_postings.map { |p|
          {
            account_id: p[:account_id],
            amount_cents: p[:amount_cents],
            property_id: p[:property_id],
            rentable_unit_id: p[:rentable_unit_id],
            tenancy_id: p[:tenancy_id],
            party_id: p[:party_id],
            memo: p[:memo]
          }
        }.sort_by(&sort_key)

        if existing_sorted == requested_sorted
          ServiceResult.success(journal_entry: entry)
        else
          ServiceResult.failure(
            error: "Posting event already exists with different posting lines",
            code: :idempotency_conflict,
            data: { journal_entry: entry }
          )
        end
      end
  end
end
