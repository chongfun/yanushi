require "rails_helper"

RSpec.describe TaxReporting::ScheduleEResult, type: :query do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:profile) { create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence") }
  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  let(:entry) do
    e = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "custom_income", source: property)
    create(:posting, journal_entry: e, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "cash"))
    e
  end
  let(:item_unresolved) do
    TaxReporting::ScheduleEResult::TaxReviewItem.new(
      id: 1,
      occurred_on: Date.new(2025, 1, 1),
      amount_cents: 10_000,
      reason: "Needs review",
      source: property,
      journal_entry: entry,
      resolution: nil,
      review_kind: :income
    )
  end
  let(:resolution) do
    create(:property_tax_review_resolution, property: property, journal_entry: entry, tax_year: 2025, treatment: "include_in_rents")
  end
  let(:item_resolved) do
    TaxReporting::ScheduleEResult::TaxReviewItem.new(
      id: 2,
      occurred_on: Date.new(2025, 2, 1),
      amount_cents: 20_000,
      reason: "Resolved",
      source: property,
      journal_entry: entry,
      resolution: resolution,
      review_kind: :expense
    )
  end

  describe "methods and calculations" do
    it "handles resolved and unresolved items and predicates" do
      expect(item_unresolved.resolved?).to be false
      expect(item_unresolved.unresolved?).to be true
      expect(item_unresolved.income?).to be true
      expect(item_unresolved.expense?).to be false
      expect(item_unresolved.treatment).to be_nil

      expect(item_resolved.resolved?).to be true
      expect(item_resolved.unresolved?).to be false
      expect(item_resolved.income?).to be false
      expect(item_resolved.expense?).to be true
      expect(item_resolved.treatment).to eq("include_in_rents")

      result = described_class.new(
        property: property,
        tax_year: 2025,
        tax_profile: profile,
        status: :ok,
        rents_received_cents: 120_000,
        expenses_by_category_cents: { repairs: 30_000, supplies: 10_000 },
        total_expenses_cents: 40_000,
        net_income_cents: 80_000,
        review_items: [ item_unresolved, item_resolved ]
      )

      expect(result.tax_profile_configured?).to be true
      expect(result.has_unresolved_reviews?).to be true
      expect(result.unresolved_review_items).to eq([ item_unresolved ])
      expect(result.resolved_review_items).to eq([ item_resolved ])
      expect(result.cents_for(:repairs)).to eq(30_000)
      expect(result.expense_for(:repairs)).to eq(300.0)
      expect(result.rents_received).to eq(1200.0)
      expect(result.total_income).to eq(1200.0)
      expect(result.total_expenses).to eq(400.0)
      expect(result.net_income).to eq(800.0)
    end

    it "evaluates can_map_to_expense? and can_include_in_rents? for various entry shapes" do
      nil_entry_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 3,
        occurred_on: Date.new(2025, 1, 1),
        amount_cents: 10_000,
        reason: "No entry",
        source: property,
        journal_entry: nil
      )
      expect(nil_entry_item.can_map_to_expense?).to be false
      expect(nil_entry_item.can_include_in_rents?).to be false

      # Pure expense entry
      expense_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "expense_posted", source: property)
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: 10_000, account: user.accounts.find_by!(key: "expense_repairs"))
      exp_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 4,
        occurred_on: Date.new(2025, 5, 1),
        amount_cents: 10_000,
        reason: "Expense",
        source: property,
        journal_entry: expense_entry
      )
      expect(exp_item.can_map_to_expense?).to be true
      expect(exp_item.can_include_in_rents?).to be false

      # Cash income entry
      income_prop = create(:property, user: user)
      income_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "custom_income_single", source: income_prop)
      create(:posting, journal_entry: income_entry, property: income_prop, amount_cents: 20_000, account: user.accounts.find_by!(key: "cash"))
      create(:posting, journal_entry: income_entry, property: income_prop, amount_cents: -20_000, account: user.accounts.find_by!(key: "rental_income"))
      inc_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 5,
        occurred_on: Date.new(2025, 5, 1),
        amount_cents: 20_000,
        reason: "Income",
        source: income_prop,
        journal_entry: income_entry
      )
      expect(inc_item.can_map_to_expense?).to be false
      expect(inc_item.can_include_in_rents?).to be true

      # Deposit applied entry
      dep_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "deposit_applied", source: property)
      create(:posting, journal_entry: dep_entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: dep_entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "security_deposits_held"))
      dep_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 6,
        occurred_on: Date.new(2025, 5, 1),
        amount_cents: 50_000,
        reason: "Deposit",
        source: property,
        journal_entry: dep_entry
      )
      expect(dep_item.can_map_to_expense?).to be false
      expect(dep_item.can_include_in_rents?).to be true

      # Reversal of deposit applied entry
      rev_dep_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 10), event_type: "reversal", reversal_of: dep_entry, source: property)
      create(:posting, journal_entry: rev_dep_entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: rev_dep_entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "security_deposits_held"))
      rev_dep_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 7,
        occurred_on: Date.new(2025, 5, 10),
        amount_cents: 50_000,
        reason: "Deposit Reversal",
        source: property,
        journal_entry: rev_dep_entry
      )
      expect(rev_dep_item.can_include_in_rents?).to be true

      # Reversal of cash inflow
      other_prop = create(:property, user: user)
      inc_entry_for_rev = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "custom_income_2", source: other_prop)
      create(:posting, journal_entry: inc_entry_for_rev, property: other_prop, amount_cents: 20_000, account: user.accounts.find_by!(key: "cash"))
      create(:posting, journal_entry: inc_entry_for_rev, property: other_prop, amount_cents: -20_000, account: user.accounts.find_by!(key: "rental_income"))
      rev_inc_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 10), event_type: "reversal", reversal_of: inc_entry_for_rev, source: other_prop)
      create(:posting, journal_entry: rev_inc_entry, property: other_prop, amount_cents: -20_000, account: user.accounts.find_by!(key: "cash"))
      create(:posting, journal_entry: rev_inc_entry, property: other_prop, amount_cents: 20_000, account: user.accounts.find_by!(key: "rental_income"))
      rev_inc_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 8,
        occurred_on: Date.new(2025, 5, 10),
        amount_cents: 20_000,
        reason: "Income Reversal",
        source: other_prop,
        journal_entry: rev_inc_entry
      )
      expect(rev_inc_item.can_include_in_rents?).to be true

      # Expense module event
      exp_module_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), source_type: "Expense", event_type: "custom_event")
      exp_module_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 9,
        occurred_on: Date.new(2025, 5, 1),
        amount_cents: 5_000,
        reason: "Expense module event",
        source: property,
        journal_entry: exp_module_entry
      )
      expect(exp_module_item.can_include_in_rents?).to be false

      # Cross-year reversal
      expect(item_unresolved.cross_year_reversal?).to be false
      expect(nil_entry_item.cross_year_reversal?).to be false
      cross_year_prop = create(:property, user: user)
      cross_year_orig = create(:journal_entry, user: user, occurred_on: Date.new(2025, 12, 1), event_type: "orig_event", source: cross_year_prop)
      cross_year_rev = create(:journal_entry, user: user, occurred_on: Date.new(2026, 1, 5), event_type: "reversal", reversal_of: cross_year_orig, source: cross_year_prop)
      cross_year_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 99,
        occurred_on: Date.new(2026, 1, 5),
        amount_cents: 20_000,
        reason: "Cross Year",
        source: cross_year_prop,
        journal_entry: cross_year_rev
      )
      expect(cross_year_item.cross_year_reversal?).to be true

      # Pure liability entry
      liab_prop = create(:property, user: user)
      liab_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), source: liab_prop, event_type: "custom_liab")
      create(:posting, journal_entry: liab_entry, property: liab_prop, amount_cents: 10_000, account: user.accounts.find_by!(key: "security_deposits_held"))
      liab_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 10,
        occurred_on: Date.new(2025, 5, 1),
        amount_cents: 10_000,
        reason: "Liability entry",
        source: property,
        journal_entry: liab_entry
      )
      expect(liab_item.can_include_in_rents?).to be false
    end

    it "handles fallback initialization and missing tax profile status" do
      other_detail = TaxReporting::ScheduleEResult::OtherExpenseDetail.new(
        id: 1,
        occurred_on: Date.new(2025, 3, 1),
        description: "Special disposal",
        amount_cents: 15_000,
        journal_entry: entry
      )
      inc_drilldown = TaxReporting::ScheduleEResult::IncomeDrilldownItem.new(
        id: 1,
        occurred_on: Date.new(2025, 3, 1),
        label: "Rent",
        description: "Monthly rent",
        amount_cents: 100_000,
        party: create(:party, user: user),
        journal_entry: entry,
        reversal: false
      )
      exp_drilldown = TaxReporting::ScheduleEResult::ExpenseDrilldownItem.new(
        id: 1,
        occurred_on: Date.new(2025, 3, 1),
        category: :repairs,
        description: "Plumbing",
        amount_cents: 20_000,
        property: property,
        rentable_unit: nil,
        journal_entry: entry,
        reversal: false
      )

      res = described_class.new(
        property: property,
        tax_year: 2025,
        tax_profile: nil,
        status: :tax_profile_required,
        rents_received_cents: 0,
        expenses_by_category_cents: nil,
        total_expenses_cents: 0,
        net_income_cents: 0,
        other_expense_details: [ other_detail ],
        rents_received_drilldown: [ inc_drilldown ],
        expense_drilldown_by_category: { repairs: [ exp_drilldown ] }
      )
      expect(res.tax_profile_configured?).to be false
      expect(res.has_unresolved_reviews?).to be false
      expect(res.cents_for(:repairs)).to eq(0)
      expect(res.expense_for("repairs")).to eq(0.0)
      expect(res.other_expense_details).to eq([ other_detail ])
      expect(res.rents_received_drilldown).to eq([ inc_drilldown ])
      expect(res.expense_drilldown_by_category[:repairs]).to eq([ exp_drilldown ])

      res_with_profile_but_error = described_class.new(
        property: property,
        tax_year: 2025,
        tax_profile: profile,
        status: :error,
        rents_received_cents: 0,
        expenses_by_category_cents: {},
        total_expenses_cents: 0,
        net_income_cents: 0
      )
      expect(res_with_profile_but_error.tax_profile_configured?).to be false
    end

    it "handles TaxReviewItem default arguments and orphan reversal entries" do
      default_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 11,
        occurred_on: Date.new(2025, 1, 1),
        amount_cents: 10_000,
        reason: "Default test",
        source: property,
        journal_entry: entry
      )
      expect(default_item.resolution).to be_nil
      expect(default_item.review_kind).to eq(:income)
      expect(default_item.resolved?).to be false
      expect(default_item.unresolved?).to be true

      # Reversal entry
      prop_for_rev = create(:property, user: user)
      orig_entry_rev = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "custom_cash", source: prop_for_rev)
      create(:posting, journal_entry: orig_entry_rev, property: prop_for_rev, amount_cents: 10_000, account: user.accounts.find_by!(key: "cash"))
      rev_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 15), event_type: "reversal", reversal_of: orig_entry_rev, source: prop_for_rev)
      create(:posting, journal_entry: rev_entry, property: prop_for_rev, amount_cents: -10_000, account: user.accounts.find_by!(key: "cash"))
      rev_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 12,
        occurred_on: Date.new(2025, 5, 15),
        amount_cents: 10_000,
        reason: "Reversal of cash entry",
        source: prop_for_rev,
        journal_entry: rev_entry
      )
      expect(rev_item.can_include_in_rents?).to be true
      expect(rev_item.cross_year_reversal?).to be false
      expect(rev_item.income?).to be true
      expect(rev_item.expense?).to be false

      # Expense review kind
      exp_kind_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 13,
        occurred_on: Date.new(2025, 5, 15),
        amount_cents: 5_000,
        reason: "Expense review",
        source: property,
        journal_entry: entry,
        review_kind: :expense
      )
      expect(exp_kind_item.income?).to be false
      expect(exp_kind_item.expense?).to be true

      # Cross year reversal
      prop_cross = create(:property, user: user)
      orig_cross = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "custom_cash_2", source: prop_cross)
      create(:posting, journal_entry: orig_cross, property: prop_cross, amount_cents: 10_000, account: user.accounts.find_by!(key: "cash"))
      cross_year_rev = create(:journal_entry, user: user, occurred_on: Date.new(2026, 1, 15), event_type: "reversal", reversal_of: orig_cross, source: prop_cross)
      cross_year_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 14,
        occurred_on: Date.new(2026, 1, 15),
        amount_cents: 10_000,
        reason: "Cross year reversal",
        source: prop_cross,
        journal_entry: cross_year_rev
      )
      expect(cross_year_item.cross_year_reversal?).to be true
      expect(cross_year_item.resolution_target).to eq(orig_cross)

      # Non-reversal item
      non_rev_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 15,
        occurred_on: Date.new(2025, 5, 1),
        amount_cents: 10_000,
        reason: "Original",
        source: prop_for_rev,
        journal_entry: orig_entry_rev
      )
      expect(non_rev_item.cross_year_reversal?).to be false
      expect(non_rev_item.resolution_target).to eq(orig_entry_rev)

      # Nil journal entry
      nil_entry_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 16,
        occurred_on: Date.new(2025, 5, 1),
        amount_cents: 10_000,
        reason: "Nil entry",
        source: prop_for_rev,
        journal_entry: nil
      )
      expect(nil_entry_item.resolution_target).to be_nil
      expect(nil_entry_item.cross_year_reversal?).to be false
      expect(nil_entry_item.can_map_to_expense?).to be false
      expect(nil_entry_item.can_include_in_rents?).to be false
      expect(nil_entry_item.treatment).to be_nil

      # Same year reversal
      prop_same = create(:property, user: user)
      orig_same = create(:journal_entry, user: user, occurred_on: Date.new(2025, 6, 1), event_type: "custom_cash_same", source: prop_same)
      create(:posting, journal_entry: orig_same, property: prop_same, amount_cents: 10_000, account: user.accounts.find_by!(key: "cash"))
      same_year_rev = create(:journal_entry, user: user, occurred_on: Date.new(2025, 7, 15), event_type: "reversal", reversal_of: orig_same, source: prop_same)
      same_year_item = TaxReporting::ScheduleEResult::TaxReviewItem.new(
        id: 17,
        occurred_on: Date.new(2025, 7, 15),
        amount_cents: 10_000,
        reason: "Same year reversal",
        source: prop_same,
        journal_entry: same_year_rev
      )
      expect(same_year_item.cross_year_reversal?).to be false
    end
  end
end
