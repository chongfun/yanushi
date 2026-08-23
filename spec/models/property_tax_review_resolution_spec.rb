require "rails_helper"

RSpec.describe PropertyTaxReviewResolution, type: :model do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:other_property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
  end

  let(:cash_account) { user.accounts.find_by!(key: "cash") }
  let(:revenue_account) { user.accounts.find_by!(key: "rental_income") }
  let(:expense_account) { create(:account, user: user, key: "custom_unmapped", account_type: "expense") }
  let(:liability_account) { create(:account, user: user, key: "custom_liability", account_type: "liability") }

  let(:journal_entry) do
    entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "custom_income", source: property)
    create(:posting, journal_entry: entry, property: property, amount_cents: 50_000, account: cash_account)
    create(:posting, journal_entry: entry, property: property, amount_cents: -50_000, account: revenue_account)
    entry
  end

  subject do
    described_class.new(
      property: property,
      journal_entry: journal_entry,
      tax_year: 2025,
      treatment: "include_in_rents"
    )
  end

  describe "validations" do
    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:tax_year) }
    it { is_expected.to validate_presence_of(:treatment) }

    it "validates uniqueness of journal_entry scoped to property and tax_year" do
      subject.save!
      duplicate = described_class.new(
        property: property,
        journal_entry: journal_entry,
        tax_year: 2025,
        treatment: "exclude"
      )
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:journal_entry_id]).to include("has already been resolved for this tax year")
    end

    it "validates that tax_year must match the journal entry occurred_on year" do
      subject.tax_year = 2026
      expect(subject).not_to be_valid
      expect(subject.errors[:tax_year]).to include("must match the year the journal entry occurred (2025)")
    end

    it "validates that tax_year is within 1901..2099 boundary" do
      entry_old = create(:journal_entry, user: user, occurred_on: Date.new(1900, 1, 1))
      res_old = described_class.new(property: property, journal_entry: entry_old, tax_year: 1900, treatment: "exclude")
      expect(res_old).not_to be_valid

      entry_future = create(:journal_entry, user: user, occurred_on: Date.new(2100, 1, 1))
      res_future = described_class.new(property: property, journal_entry: entry_future, tax_year: 2100, treatment: "exclude")
      expect(res_future).not_to be_valid
    end

    it "validates that journal_entry must belong to the same user as property" do
      entry_other_user = create(:journal_entry, user: other_user, occurred_on: Date.new(2025, 6, 1))
      subject.journal_entry = entry_other_user
      expect(subject).not_to be_valid
      expect(subject.errors[:journal_entry]).to include("must belong to the same user as the property")
    end

    it "validates that journal_entry must have postings for the property" do
      entry_other_prop = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1))
      create(:posting, journal_entry: entry_other_prop, property: other_property, amount_cents: 10_000, account: cash_account)
      create(:posting, journal_entry: entry_other_prop, property: other_property, amount_cents: -10_000, account: revenue_account)

      subject.journal_entry = entry_other_prop
      expect(subject).not_to be_valid
      expect(subject.errors[:journal_entry]).to include("does not have any postings for this property")
    end

    it "rejects include_in_rents treatment for expense-only entries" do
      expense_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "expense_posted")
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: 800_000, account: expense_account)
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: -800_000, account: liability_account)

      resolution = described_class.new(
        property: property,
        journal_entry: expense_entry,
        tax_year: 2025,
        treatment: "include_in_rents"
      )
      expect(resolution).not_to be_valid
      expect(resolution.errors[:treatment]).to include("cannot include an expense or non-cash/deposit entry in rental income")
    end

    it "requires schedule_e_category when treatment is map_to_schedule_e_category" do
      expense_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "expense_posted")
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: 800_000, account: expense_account)

      resolution = described_class.new(
        property: property,
        journal_entry: expense_entry,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: nil
      )
      expect(resolution).not_to be_valid
      expect(resolution.errors[:schedule_e_category]).to be_present

      resolution.schedule_e_category = "repairs"
      expect(resolution).to be_valid
    end

    it "rejects map_to_schedule_e_category for non-expense entries" do
      resolution = described_class.new(
        property: property,
        journal_entry: journal_entry,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "repairs"
      )
      expect(resolution).not_to be_valid
      expect(resolution.errors[:treatment]).to include("cannot map a non-expense entry to a Schedule E expense category")
    end

    it "allows exclude treatment for any valid review item entry" do
      resolution = described_class.new(
        property: property,
        journal_entry: journal_entry,
        tax_year: 2025,
        treatment: "exclude"
      )
      expect(resolution).to be_valid
    end

    it "validates property association via rentable_unit or tenancy" do
      unit = create(:rentable_unit, property: property)
      tenancy = create(:tenancy, rentable_unit: unit)
      entry_unit = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "custom_income", source: property)
      create(:posting, journal_entry: entry_unit, property: nil, rentable_unit: unit, amount_cents: 10_000, account: cash_account)
      create(:posting, journal_entry: entry_unit, property: nil, rentable_unit: unit, amount_cents: -10_000, account: revenue_account)

      res_unit = described_class.new(property: property, journal_entry: entry_unit, tax_year: 2025, treatment: "include_in_rents")
      expect(res_unit).to be_valid

      entry_tenancy = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "custom_income", source: user)
      create(:posting, journal_entry: entry_tenancy, property: nil, rentable_unit: nil, tenancy: tenancy, amount_cents: 10_000, account: cash_account)
      create(:posting, journal_entry: entry_tenancy, property: nil, rentable_unit: nil, tenancy: tenancy, amount_cents: -10_000, account: revenue_account)

      res_tenancy = described_class.new(property: property, journal_entry: entry_tenancy, tax_year: 2025, treatment: "include_in_rents")
      expect(res_tenancy).to be_valid
    end

    it "rejects resolutions for reversal entries because tax treatment is derived from original event" do
      orig_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "deposit_applied", source: property)
      create(:posting, journal_entry: orig_entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: orig_entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      reversal_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 15), event_type: "reversal", reversal_of: orig_entry, source: property)
      create(:posting, journal_entry: reversal_entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: reversal_entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      res_rev = described_class.new(property: property, journal_entry: reversal_entry, tax_year: 2025, treatment: "include_in_rents")
      expect(res_rev).not_to be_valid
      expect(res_rev.errors[:journal_entry]).to include("is a reversal; tax treatment is automatically derived from the original event")
    end

    it "allows include_in_rents treatment for deposit_applied entries" do
      dep_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "deposit_applied", source: property)
      create(:posting, journal_entry: dep_entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: dep_entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      res = described_class.new(property: property, journal_entry: dep_entry, tax_year: 2025, treatment: "include_in_rents")
      expect(res).to be_valid
    end

    it "rejects include_in_rents treatment for entry with source_type Expense" do
      exp = create(:expense, property: property, expense_kind: "repairs", amount_cents: 10_000)
      exp_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "custom_event", source: exp)
      create(:posting, journal_entry: exp_entry, property: property, amount_cents: 10_000, account: cash_account)
      res = described_class.new(property: property, journal_entry: exp_entry, tax_year: 2025, treatment: "include_in_rents")
      expect(res).not_to be_valid
    end

    it "rejects include_in_rents treatment for entry with cash outflow only" do
      outflow_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "cash_outflow", source: property)
      create(:posting, journal_entry: outflow_entry, property: property, amount_cents: -10_000, account: cash_account)
      create(:posting, journal_entry: outflow_entry, property: property, amount_cents: 10_000, account: liability_account)
      res = described_class.new(property: property, journal_entry: outflow_entry, tax_year: 2025, treatment: "include_in_rents")
      expect(res).not_to be_valid
    end

    it "validates cleanly when property or journal_entry is missing" do
      res = described_class.new(property: nil, journal_entry: nil)
      expect(res).not_to be_valid
    end

    it "rejects exclude and map_to_schedule_e_category for ordinary already-mapped expense_posted entries" do
      expense = create(:expense, property: property)
      expense_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "expense_posted", source: expense)
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: 10_000, account: user.accounts.find_by!(key: "expense_repairs"))
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: -10_000, account: cash_account)

      # 1. Reject exclude
      res_exclude = described_class.new(
        property: property,
        journal_entry: expense_entry,
        tax_year: 2025,
        treatment: "exclude"
      )
      expect(res_exclude).not_to be_valid
      expect(res_exclude.errors[:journal_entry]).to include("does not require tax review; resolution cannot be attached")

      # 2. Reject map_to_schedule_e_category
      res_map = described_class.new(
        property: property,
        journal_entry: expense_entry,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "advertising"
      )
      expect(res_map).not_to be_valid
      expect(res_map.errors[:journal_entry]).to include("does not require tax review; resolution cannot be attached")
    end

    it "allows map_to_schedule_e_category and exclude for unmapped expense accounts on expense_posted entries" do
      unmapped_acct = create(:account, user: user, key: "expense_consulting_custom", account_type: "expense")
      expense = create(:expense, property: property)
      expense_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "expense_posted", source: expense)
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: 10_000, account: unmapped_acct)
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: -10_000, account: cash_account)

      res_map = described_class.new(
        property: property,
        journal_entry: expense_entry,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "other"
      )
      expect(res_map).to be_valid

      res_exclude = described_class.new(
        property: property,
        journal_entry: expense_entry,
        tax_year: 2025,
        treatment: "exclude"
      )
      expect(res_exclude).to be_valid
    end

    it "rejects resolution when journal entry contains multiple distinct unmapped expense accounts for the same property" do
      unmapped_acct1 = create(:account, user: user, key: "expense_landscaping_custom", account_type: "expense")
      unmapped_acct2 = create(:account, user: user, key: "expense_legal_custom", account_type: "expense")
      expense = create(:expense, property: property)
      multi_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "expense_posted", source: expense)
      create(:posting, journal_entry: multi_entry, property: property, amount_cents: 10_000, account: unmapped_acct1)
      create(:posting, journal_entry: multi_entry, property: property, amount_cents: 20_000, account: unmapped_acct2)
      create(:posting, journal_entry: multi_entry, property: property, amount_cents: -30_000, account: cash_account)

      res = described_class.new(
        property: property,
        journal_entry: multi_entry,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "repairs"
      )
      expect(res).not_to be_valid
      expect(res.errors[:journal_entry]).to include("contains multiple distinct unmapped expense accounts for this property and cannot be resolved with a single journal-entry-level resolution")
    end

    it "allows independent resolutions when a multi-property journal entry has one unmapped expense per property" do
      prop_b = create(:property, user: user)
      exp = create(:expense, property: property)
      unmapped_acct1 = create(:account, user: user, key: "expense_landscaping_a", account_type: "expense")
      unmapped_acct2 = create(:account, user: user, key: "expense_legal_b", account_type: "expense")

      entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "expense_posted", source: exp)
      create(:posting, journal_entry: entry, property: property, amount_cents: 10_000, account: unmapped_acct1)
      create(:posting, journal_entry: entry, property: property, amount_cents: -10_000, account: cash_account)
      create(:posting, journal_entry: entry, property: prop_b, amount_cents: 20_000, account: unmapped_acct2)
      create(:posting, journal_entry: entry, property: prop_b, amount_cents: -20_000, account: cash_account)

      res_a = described_class.new(
        property: property,
        journal_entry: entry,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "repairs"
      )
      expect(res_a).to be_valid

      res_b = described_class.new(
        property: prop_b,
        journal_entry: entry,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "legal_and_professional"
      )
      expect(res_b).to be_valid
    end

    it "resolves property via unit and tenancy postings" do
      exp = create(:expense, property: property)
      unmapped_acct = create(:account, user: user, key: "expense_unit_res_unmapped", account_type: "expense")
      entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "expense_posted", source: exp)
      create(:posting, journal_entry: entry, property: nil, rentable_unit: unit, amount_cents: 10_000, account: unmapped_acct)
      create(:posting, journal_entry: entry, property: nil, tenancy: tenancy, amount_cents: -10_000, account: cash_account)

      res = described_class.new(
        property: property,
        journal_entry: entry,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "repairs"
      )
      expect(res).to be_valid
    end
  end

  describe "predicate helpers" do
    it "identifies treatments correctly" do
      res = described_class.new(treatment: "include_in_rents")
      expect(res.include_in_rents?).to be true
      expect(res.map_to_schedule_e_category?).to be false
      expect(res.exclude?).to be false

      res_map = described_class.new(treatment: "map_to_schedule_e_category")
      expect(res_map.include_in_rents?).to be false
      expect(res_map.map_to_schedule_e_category?).to be true
      expect(res_map.exclude?).to be false

      res_ex = described_class.new(treatment: "exclude")
      expect(res_ex.include_in_rents?).to be false
      expect(res_ex.map_to_schedule_e_category?).to be false
      expect(res_ex.exclude?).to be true
    end
  end
end
