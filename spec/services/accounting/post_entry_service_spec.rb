require "rails_helper"

RSpec.describe Accounting::PostEntryService do
  let!(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:dummy_source) { create(:expense, property: property) }

  let(:postings) do
    [
      Accounting::PostingSpec.new(
        account_key: "tenant_receivable",
        amount_cents: 200_000,
        tenancy: tenancy
      ),
      Accounting::PostingSpec.new(
        account_key: "rental_income",
        amount_cents: -200_000,
        tenancy: tenancy
      )
    ]
  end

  describe ".call" do
    it "persists a balanced journal entry and postings atomically" do
      expect {
        result = described_class.call(
          user: user,
          source: dummy_source,
          event_type: "rent_assessed",
          occurred_on: Date.new(2026, 1, 1),
          description: "January 2026 Rent",
          postings: postings
        )

        expect(result).to be_success
        entry = result.value!.data[:journal_entry]
        expect(entry).to be_persisted
        expect(entry.user_id).to eq(user.id)
        expect(entry.source_type).to eq("Expense")
        expect(entry.source_id).to eq(dummy_source.id)
        expect(entry.event_type).to eq("rent_assessed")
        expect(entry.occurred_on).to eq(Date.new(2026, 1, 1))
        expect(entry.description).to eq("January 2026 Rent")
        expect(entry.posted_at).to be_present
        expect(entry.postings.count).to eq(2)
        expect(entry.postings.sum(:amount_cents)).to eq(0)
      }.to change(JournalEntry, :count).by(1).and change(Posting, :count).by(2)
    end

    it "is idempotent on exact retry and returns the existing entry without creating new records" do
      first_result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.new(2026, 1, 1),
        description: "January 2026 Rent",
        postings: postings
      )
      expect(first_result).to be_success
      first_entry = first_result.value!.data[:journal_entry]

      expect {
        retry_result = described_class.call(
          user: user,
          source: dummy_source,
          event_type: "rent_assessed",
          occurred_on: Date.new(2026, 1, 1),
          description: "January 2026 Rent",
          postings: postings
        )

        expect(retry_result).to be_success
        expect(retry_result.value!.data[:journal_entry].id).to eq(first_entry.id)
      }.not_to change(JournalEntry, :count)
    end

    it "fails with :idempotency_conflict when repeating same source identity with changed amount" do
      described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.new(2026, 1, 1),
        postings: postings
      )

      conflicting_postings = [
        Accounting::PostingSpec.new(account_key: "tenant_receivable", amount_cents: 250_000, tenancy: tenancy),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -250_000, tenancy: tenancy)
      ]

      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.new(2026, 1, 1),
        postings: conflicting_postings
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:idempotency_conflict)
      expect(result.failure.error).to include("already exists with different")
    end

    it "fails with :idempotency_conflict when repeating same source identity with changed date" do
      described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.new(2026, 1, 1),
        postings: postings
      )

      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.new(2026, 2, 1),
        postings: postings
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:idempotency_conflict)
    end

    it "rejects a source belonging to a different user" do
      other_user = create(:user)
      other_property = create(:property, user: other_user)
      other_expense = create(:expense, property: other_property)

      result = described_class.call(
        user: user,
        source: other_expense,
        event_type: "expense_posted",
        occurred_on: Date.current,
        postings: postings
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:ownership_mismatch)
      expect(result.failure.error).to include("Source does not belong to user")
    end

    it "rejects a RentTerm belonging to a different user when user is passed explicitly" do
      other_user = create(:user)
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit, agreement_type: "month_to_month", commencement_date: Date.new(2026, 1, 1), termination_date: nil)
      other_term = create(:rent_term, tenancy: other_tenancy, amount_cents: 150_000, effective_from: Date.new(2026, 1, 1))

      result = described_class.call(
        user: user,
        source: other_term,
        event_type: "rent_scheduled",
        occurred_on: Date.current,
        postings: postings
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:ownership_mismatch)
      expect(result.failure.error).to include("Source does not belong to user")
    end

    it "rejects a source that does not implement accounting_user" do
      dummy_record = create(:user)
      dummy_record.singleton_class.undef_method(:accounting_user)

      result = described_class.call(
        user: user,
        source: dummy_record,
        event_type: "custom_event",
        occurred_on: Date.current,
        postings: postings
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_source)
      expect(result.failure.error).to include("Source must implement accounting_user")
    end

    it "fails when source accounting_user is nil or unpersisted" do
      orphan_expense = create(:expense, property: property)
      allow(orphan_expense).to receive(:accounting_user).and_return(nil)

      result = described_class.call(
        user: user,
        source: orphan_expense,
        event_type: "expense_posted",
        occurred_on: Date.current,
        postings: postings
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_source)
      expect(result.failure.error).to include("Source accounting_user must be a persisted user")
    end

    it "fails when event_type is blank" do
      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "",
        occurred_on: Date.current,
        postings: postings
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
    end

    it "fails when occurred_on is nil" do
      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: nil,
        postings: postings
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
    end

    it "fails when occurred_on is an invalid date string" do
      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: "not-a-date",
        postings: postings
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
      expect(result.failure.error).to include("Occurred on must be a valid date")
    end

    it "fails when source is destroyed" do
      dummy_source.destroy
      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.current,
        postings: postings
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_source)
    end

    it "accepts a string date for occurred_on" do
      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed_string_date",
        occurred_on: "2026-03-01",
        postings: postings
      )
      expect(result).to be_success
      expect(result.value!.data[:journal_entry].occurred_on).to eq(Date.new(2026, 3, 1))
    end

    it "fails with :idempotency_conflict when repeating same source identity with changed description" do
      described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.new(2026, 1, 1),
        description: "Initial description",
        postings: postings
      )

      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.new(2026, 1, 1),
        description: "Altered description",
        postings: postings
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:idempotency_conflict)
    end

    it "fails with :idempotency_conflict when repeating same source identity with different posting count" do
      described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.new(2026, 1, 1),
        postings: postings
      )

      three_line_postings = [
        Accounting::PostingSpec.new(account_key: "tenant_receivable", amount_cents: 100_000, tenancy: tenancy),
        Accounting::PostingSpec.new(account_key: "tenant_receivable", amount_cents: 100_000, tenancy: tenancy),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -200_000, tenancy: tenancy)
      ]

      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed",
        occurred_on: Date.new(2026, 1, 1),
        postings: three_line_postings
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:idempotency_conflict)
    end

    it "handles RecordInvalid during journal entry creation" do
      allow(JournalEntry).to receive(:transaction).and_raise(ActiveRecord::RecordInvalid.new(JournalEntry.new))

      result = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed_invalid",
        occurred_on: Date.current,
        postings: postings
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:validation_error)
    end

    it "rolls back everything if one posting fails persistence" do
      unpersisted = build(:expense, property: property)
      result = described_class.call(
        user: user,
        source: unpersisted,
        event_type: "rent_assessed",
        occurred_on: Date.current,
        postings: postings
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_source)
    end

    it "rolls back journal entry if posting creation fails mid-transaction" do
      allow_any_instance_of(Posting).to receive(:valid?).and_return(true)
      allow_any_instance_of(Posting).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(Posting.new))

      expect {
        result = described_class.call(
          user: user,
          source: dummy_source,
          event_type: "rent_assessed",
          occurred_on: Date.current,
          postings: postings
        )
        expect(result).to be_failure
      }.not_to change(JournalEntry, :count)
    end

    it "accepts date string, Date object, and rejects invalid date or blank event type" do
      res1 = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed_string_date",
        occurred_on: "2026-01-15",
        postings: postings
      )
      expect(res1).to be_success
      expect(res1.value!.data[:journal_entry].occurred_on).to eq(Date.new(2026, 1, 15))

      res_bad_date = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "rent_assessed_bad_date",
        occurred_on: "not-a-date",
        postings: postings
      )
      expect(res_bad_date).to be_failure
      expect(res_bad_date.failure.code).to eq(:invalid_input)

      res_blank_event = described_class.call(
        user: user,
        source: dummy_source,
        event_type: "",
        occurred_on: Date.current,
        postings: postings
      )
      expect(res_blank_event).to be_failure
      expect(res_blank_event.failure.code).to eq(:invalid_input)
    end

    describe "concurrency race recovery" do
      it "recovers from RecordNotUnique race when parallel process commits first" do
        # Another process committed the entry in parallel
        parallel_entry = JournalEntry.create!(
          user: user,
          source_type: "Expense",
          source_id: dummy_source.id,
          event_type: "rent_assessed",
          occurred_on: Date.new(2026, 1, 1),
          posted_at: Time.current
        )
        parallel_entry.postings.create!(account: user.accounts.find_by!(key: "tenant_receivable"), amount_cents: 200_000, tenancy: tenancy, property: property, rentable_unit: unit)
        parallel_entry.postings.create!(account: user.accounts.find_by!(key: "rental_income"), amount_cents: -200_000, tenancy: tenancy, property: property, rentable_unit: unit)

        call_count = 0
        allow(JournalEntry).to receive(:find_by).and_wrap_original do |original_method, *args|
          call_count += 1
          if call_count == 1
            nil # Initial pre-check returns nil, simulating race before creation
          else
            original_method.call(*args)
          end
        end

        allow(user.journal_entries).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique, "PG::UniqueViolation")

        result = described_class.call(
          user: user,
          source: dummy_source,
          event_type: "rent_assessed",
          occurred_on: Date.new(2026, 1, 1),
          postings: postings
        )

        expect(result).to be_success
        expect(result.value!.data[:journal_entry].id).to eq(parallel_entry.id)
      end
    end
  end
end
