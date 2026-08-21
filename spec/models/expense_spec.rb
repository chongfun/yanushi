require "rails_helper"

RSpec.describe Expense, type: :model do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }

  describe "associations" do
    it { is_expected.to belong_to(:property) }
    it { is_expected.to belong_to(:rentable_unit).optional }
    it { is_expected.to belong_to(:superseded_by).class_name("Expense").optional }
    it { is_expected.to have_one(:superseded_expense).class_name("Expense").with_foreign_key(:superseded_by_id) }
    it { is_expected.to have_many(:journal_entries).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:charges).with_foreign_key(:source_expense_id).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:reimbursement_charges).class_name("Charge").with_foreign_key(:source_expense_id).dependent(:restrict_with_error) }
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:expense_kind).with_values(
      advertising: "advertising",
      auto_and_travel: "auto_and_travel",
      cleaning_and_maintenance: "cleaning_and_maintenance",
      commissions: "commissions",
      insurance: "insurance",
      legal_and_professional: "legal_and_professional",
      management: "management",
      mortgage_interest: "mortgage_interest",
      other_interest: "other_interest",
      repairs: "repairs",
      supplies: "supplies",
      taxes: "taxes",
      utilities: "utilities",
      other: "other"
    ).backed_by_column_of_type(:string) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:property) }
    it { is_expected.to validate_presence_of(:expense_kind) }
    it { is_expected.to validate_presence_of(:amount_cents) }
    it { is_expected.to validate_numericality_of(:amount_cents).only_integer.is_greater_than(0) }
    it { is_expected.to validate_presence_of(:paid_on) }

    it "validates that rentable_unit belongs to property" do
      other_prop = create(:property, user: user)
      foreign_unit = create(:rentable_unit, property: other_prop)
      expense = build(:expense, property: property, rentable_unit: foreign_unit)

      expect(expense).not_to be_valid
      expect(expense.errors[:rentable_unit]).to include("must belong to the selected property")
    end

    it "allows rentable_unit belonging to the same property" do
      expense = build(:expense, property: property, rentable_unit: unit)
      expect(expense).to be_valid
    end

    it "validates superseded_by belongs to the same user" do
      other_user = create(:user)
      other_prop = create(:property, user: other_user)
      other_expense = create(:expense, property: other_prop)

      expense = build(:expense, property: property, superseded_by: other_expense)
      expect(expense).not_to be_valid
      expect(expense.errors[:superseded_by]).to include("must belong to the same user")
    end
  end

  describe "money helpers" do
    it "converts amount_cents to decimal amount" do
      expense = build(:expense, amount_cents: 12_550)
      expect(expense.amount).to eq(125.50)

      expense.amount_cents = nil
      expect(expense.amount).to eq(0)
    end

    it "converts amount= to amount_cents" do
      expense = build(:expense)
      expense.amount = "250.75"
      expect(expense.amount_cents).to eq(25_075)

      expense.amount = ""
      expect(expense.amount_cents).to eq(0)

      expense.amount = nil
      expect(expense.amount_cents).to eq(0)

      expense.amount = "invalid"
      expect(expense.amount_cents).to eq(0)
    end
  end

  describe "scopes and lifecycle predicates" do
    it "correctly filters active, voided, posted" do
      active_exp = create(:expense, property: property, posted_at: Time.current)
      voided_exp = create(:expense, :voided, property: property)
      unposted_exp = create(:expense, property: property, posted_at: nil)

      expect(described_class.active).to include(active_exp, unposted_exp)
      expect(described_class.active).not_to include(voided_exp)

      expect(described_class.voided).to include(voided_exp)
      expect(described_class.voided).not_to include(active_exp)

      expect(described_class.posted).to include(active_exp, voided_exp)
      expect(described_class.posted).not_to include(unposted_exp)

      expect(active_exp.posted?).to be true
      expect(active_exp.active?).to be true
      expect(active_exp.voided?).to be false

      expect(voided_exp.voided?).to be true
      expect(voided_exp.active?).to be false
    end

    it "determines lifecycle_status correctly with superseded taking precedence over voided" do
      replacement = create(:expense, property: property)
      superseded_exp = create(:expense, property: property, posted_at: Time.current, voided_at: Time.current, superseded_by: replacement)
      voided_exp = create(:expense, property: property, posted_at: Time.current, voided_at: Time.current)
      active_exp = create(:expense, property: property, posted_at: Time.current, voided_at: nil)
      draft_exp = create(:expense, property: property, posted_at: nil, voided_at: nil)

      expect(superseded_exp.lifecycle_status).to eq(:superseded)
      expect(voided_exp.lifecycle_status).to eq(:voided)
      expect(active_exp.lifecycle_status).to eq(:posted)
      expect(draft_exp.lifecycle_status).to eq(:draft)
    end
  end

  describe "immutability once posted" do
    let!(:expense) { create(:expense, :posted, property: property) }

    it "rejects changes to core financial attributes once posted" do
      expect {
        expense.update(amount_cents: 99_999)
      }.not_to change { expense.reload.amount_cents }
      expect(expense.errors[:amount_cents]).to include("cannot be modified after expense is posted")
    end

    it "rejects changing property once posted" do
      other_prop = create(:property, user: user)
      expense.update(property: other_prop)
      expect(expense.errors[:property_id]).to include("cannot be modified after expense is posted")
    end

    it "rejects changing paid_on once posted" do
      expense.update(paid_on: 10.days.ago)
      expect(expense.errors[:paid_on]).to include("cannot be modified after expense is posted")
    end

    it "rejects changing expense_kind once posted" do
      expense.update(expense_kind: "utilities")
      expect(expense.errors[:expense_kind]).to include("cannot be modified after expense is posted")
    end

    it "rejects directly modifying voided_at, posted_at, or superseded_by_id" do
      expense.update(voided_at: Time.current)
      expect(expense.errors[:voided_at]).to include("cannot be modified directly; use Expenses::VoidService")

      expense.update(posted_at: Time.current + 1.day)
      expect(expense.errors[:posted_at]).to include("cannot be modified once posted")

      expense.update(superseded_by_id: 123)
      expect(expense.errors[:superseded_by_id]).to include("cannot be modified directly")
    end

    it "rejects hard deletion once posted" do
      expect {
        expense.destroy
      }.not_to change(described_class, :count)
      expect(expense.errors[:base]).to include("Cannot delete a posted expense. Void the expense instead.")
    end

    it "allows hard deletion of unposted expense without journal entries" do
      unposted = create(:expense, property: property, posted_at: nil)
      expect {
        unposted.destroy
      }.to change(described_class, :count).by(-1)
    end
  end

  describe "#accounting_user" do
    it "returns the property user" do
      expense = build(:expense, property: property)
      expect(expense.accounting_user).to eq(user)
    end
  end
end
