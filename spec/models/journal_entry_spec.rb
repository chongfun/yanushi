require "rails_helper"

RSpec.describe JournalEntry, type: :model do
  let(:user) { create(:user) }
  let(:journal_entry) do
    create(:journal_entry,
      user: user,
      source_type: "Expense",
      source_id: 123,
      event_type: "expense_posted",
      occurred_on: Date.current,
      posted_at: Time.current
    )
  end

  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:reversal_of).class_name("JournalEntry").optional }
    it { is_expected.to have_one(:reversal).class_name("JournalEntry").with_foreign_key(:reversal_of_id).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:postings).dependent(:restrict_with_error) }
  end

  describe "validations" do
    subject { build(:journal_entry, user: user) }

    it { is_expected.to validate_presence_of(:source_type) }
    it { is_expected.to validate_presence_of(:source_id) }
    it { is_expected.to validate_presence_of(:event_type) }
    it { is_expected.to validate_presence_of(:occurred_on) }
    it { is_expected.to validate_presence_of(:posted_at) }

    it "requires source_id to be positive" do
      entry = build(:journal_entry, user: user, source_id: 0)
      expect(entry).not_to be_valid
      expect(entry.errors[:source_id]).to include("must be greater than 0")

      entry.source_id = -5
      expect(entry).not_to be_valid
    end

    it "validates uniqueness of source-event tuple scoped to user" do
      create(:journal_entry, user: user, source_type: "Expense", source_id: 101, event_type: "expense_posted")
      duplicate = build(:journal_entry, user: user, source_type: "Expense", source_id: 101, event_type: "expense_posted")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:source_id]).to include("has already been posted for this event")
    end

    it "allows the same source event for a different user" do
      other_user = create(:user)
      create(:journal_entry, user: user, source_type: "Expense", source_id: 101, event_type: "expense_posted")
      other_entry = build(:journal_entry, user: other_user, source_type: "Expense", source_id: 101, event_type: "expense_posted")
      expect(other_entry).to be_valid
    end

    it "enforces that an entry can only be reversed once" do
      original = create(:journal_entry, user: user, source_type: "Expense", source_id: 201, event_type: "expense_posted")
      create(:journal_entry, user: user, source_type: "JournalEntry", source_id: original.id, event_type: "reversal", reversal_of: original)

      second_reversal = build(:journal_entry, user: user, source_type: "JournalEntry", source_id: original.id, event_type: "reversal_2", reversal_of: original)
      expect(second_reversal).not_to be_valid
      expect(second_reversal.errors[:reversal_of_id]).to include("has already been reversed")
    end
  end

  describe "immutability" do
    let!(:persisted) { create(:journal_entry, user: user, description: "Initial") }

    it "prevents updating attributes" do
      expect {
        persisted.update!(description: "Modified")
      }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(persisted.reload.description).to eq("Initial")
    end

    it "prevents deletion" do
      expect {
        persisted.destroy!
      }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(JournalEntry.exists?(persisted.id)).to be(true)
    end
  end

  describe "reversal helpers" do
    let(:original) { create(:journal_entry, user: user, source_type: "Expense", source_id: 301, event_type: "expense_posted") }

    it "correctly identifies reversal state" do
      expect(original.reversed?).to be(false)
      expect(original.reversal?).to be(false)

      reversal = create(:journal_entry,
        user: user,
        source_type: "JournalEntry",
        source_id: original.id,
        event_type: "reversal",
        reversal_of: original
      )

      expect(original.reload.reversed?).to be(true)
      expect(reversal.reversal?).to be(true)
      expect(reversal.reversed?).to be(false)
    end

    it "returns user for accounting_user" do
      expect(original.accounting_user).to eq(user)
    end
  end
end
