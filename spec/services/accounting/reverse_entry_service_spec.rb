require "rails_helper"

RSpec.describe Accounting::ReverseEntryService do
  let!(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:dummy_source) { create(:expense, property: property) }

  let!(:original_entry) do
    entry = create(:journal_entry,
      user: user,
      source_type: "Expense",
      source_id: dummy_source.id,
      event_type: "expense_posted",
      occurred_on: Date.new(2026, 1, 15),
      description: "Original repair expense"
    )

    entry.postings.create!(
      account: user.accounts.find_by!(key: "expense_repairs"),
      amount_cents: 50_000,
      property: property,
      rentable_unit: unit,
      tenancy: tenancy,
      party: party,
      memo: "Plumbing repair"
    )

    entry.postings.create!(
      account: user.accounts.find_by!(key: "cash"),
      amount_cents: -50_000,
      property: property,
      rentable_unit: unit,
      tenancy: tenancy,
      party: party,
      memo: "Plumbing payment"
    )

    entry
  end

  describe ".call" do
    it "creates a balanced reversal entry that negates the original postings without modifying original" do
      original_desc = original_entry.description
      original_postings_count = original_entry.postings.count

      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 1, 20),
        description: "Reversing incorrect expense"
      )

      expect(result).to be_success
      reversal = result.value!.data[:journal_entry]

      # Original entry check
      expect(original_entry.reload.description).to eq(original_desc)
      expect(original_entry.postings.count).to eq(original_postings_count)
      expect(original_entry.reversed?).to be(true)
      expect(original_entry.reversal).to eq(reversal)

      # Reversal entry check
      expect(reversal).to be_persisted
      expect(reversal.user_id).to eq(user.id)
      expect(reversal.source_type).to eq("JournalEntry")
      expect(reversal.source_id).to eq(original_entry.id)
      expect(reversal.event_type).to eq("reversal")
      expect(reversal.reversal_of_id).to eq(original_entry.id)
      expect(reversal.occurred_on).to eq(Date.new(2026, 1, 20))
      expect(reversal.description).to eq("Reversing incorrect expense")
      expect(reversal.reversal?).to be(true)
      expect(reversal.reversed?).to be(false)

      # Reversal postings check
      expect(reversal.postings.count).to eq(2)
      expect(reversal.postings.sum(:amount_cents)).to eq(0)

      repairs_rev = reversal.postings.find_by(account: user.accounts.find_by(key: "expense_repairs"))
      expect(repairs_rev.amount_cents).to eq(-50_000)
      expect(repairs_rev.property_id).to eq(property.id)
      expect(repairs_rev.rentable_unit_id).to eq(unit.id)
      expect(repairs_rev.tenancy_id).to eq(tenancy.id)
      expect(repairs_rev.party_id).to eq(party.id)
      expect(repairs_rev.memo).to eq("Plumbing repair")

      cash_rev = reversal.postings.find_by(account: user.accounts.find_by(key: "cash"))
      expect(cash_rev.amount_cents).to eq(50_000)
      expect(cash_rev.property_id).to eq(property.id)
      expect(cash_rev.rentable_unit_id).to eq(unit.id)
      expect(cash_rev.tenancy_id).to eq(tenancy.id)
      expect(cash_rev.party_id).to eq(party.id)
      expect(cash_rev.memo).to eq("Plumbing payment")

      # Aggregate net across original + reversal is zero
      total_cents = original_entry.postings.sum(:amount_cents) + reversal.postings.sum(:amount_cents)
      expect(total_cents).to eq(0)
    end

    it "is idempotent and returns the existing reversal on repeated exact calls" do
      first_result = described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 1, 20),
        description: "Reversal memo"
      )
      expect(first_result).to be_success
      first_reversal = first_result.value!.data[:journal_entry]

      expect {
        second_result = described_class.call(
          journal_entry: original_entry,
          occurred_on: Date.new(2026, 1, 20),
          description: "Reversal memo"
        )
        expect(second_result).to be_success
        expect(second_result.value!.data[:journal_entry].id).to eq(first_reversal.id)
      }.not_to change(JournalEntry, :count)
    end

    it "fails with :idempotency_conflict when repeating reversal with changed occurred_on" do
      described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 1, 20)
      )

      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 2, 15)
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:idempotency_conflict)
      expect(result.failure.error).to include("Reversal already exists with different details")
    end

    it "fails with :idempotency_conflict when repeating reversal with changed description" do
      described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 1, 20),
        description: "Initial description"
      )

      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 1, 20),
        description: "Altered description"
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:idempotency_conflict)
    end

    it "rejects reversal with occurred_on earlier than original journal entry occurred_on" do
      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: original_entry.occurred_on - 1.day
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_date)
      expect(result.failure.error).to include("cannot precede original entry date")
    end

    it "fails when occurred_on is an invalid date string" do
      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: "not-a-date"
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
      expect(result.failure.error).to include("Occurred on must be a valid date")
    end

    it "accepts a string date for occurred_on" do
      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: "2026-01-20"
      )
      expect(result).to be_success
      expect(result.value!.data[:journal_entry].occurred_on).to eq(Date.new(2026, 1, 20))
    end

    it "rejects missing occurred_on date" do
      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: nil
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
      expect(result.failure.error).to include("Occurred on must be a valid date")
    end

    it "handles RecordInvalid during reversal creation" do
      allow(JournalEntry).to receive(:transaction).and_raise(ActiveRecord::RecordInvalid.new(JournalEntry.new))

      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 1, 20)
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:validation_error)
    end

    it "recovers when RecordNotUnique race occurs" do
      allow(user.journal_entries).to receive(:create!).and_wrap_original do |_orig, *args|
        # Simulate parallel process creating reversal first
        reversal = user.journal_entries.create!(
          source_type: "JournalEntry",
          source_id: original_entry.id,
          event_type: "reversal",
          occurred_on: Date.new(2026, 1, 20),
          reversal_of_id: original_entry.id,
          posted_at: Time.current
        )
        raise ActiveRecord::RecordNotUnique, "PG::UniqueViolation"
      end

      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 1, 20)
      )
      expect(result).to be_success
      expect(result.value!.data[:journal_entry].reversal_of_id).to eq(original_entry.id)
    end

    it "rejects reversing a reversal entry" do
      rev_result = described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 1, 20)
      )
      expect(rev_result).to be_success
      reversal_entry = rev_result.value!.data[:journal_entry]

      result = described_class.call(
        journal_entry: reversal_entry,
        occurred_on: Date.new(2026, 1, 25)
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_reversal)
      expect(result.failure.error).to include("Cannot reverse a reversal")
    end

    it "rejects unpersisted journal entry" do
      unpersisted = build(:journal_entry, user: user)
      result = described_class.call(
        journal_entry: unpersisted,
        occurred_on: Date.current
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_source)
    end

    it "rejects destroyed journal entry" do
      entry = create(:journal_entry, user: user, source_type: "Expense", source_id: 999, event_type: "test")
      entry.delete
      result = described_class.call(
        journal_entry: entry,
        occurred_on: Date.current
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_source)
    end

    it "handles RecordNotUnique when reversal cannot be found" do
      allow_any_instance_of(ActiveRecord::Associations::CollectionProxy).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique, "PG::UniqueViolation")
      allow_any_instance_of(JournalEntry).to receive(:reversal).and_return(nil)

      result = described_class.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 1, 20)
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:idempotency_conflict)
    end
  end
end
