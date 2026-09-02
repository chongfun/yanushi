require "rails_helper"

RSpec.describe TaxReporting::ScheduleEQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(
      :tenancy,
      rentable_unit: unit,
      agreement_type: "month_to_month",
      commencement_date: Date.new(2025, 1, 1),
      termination_date: nil
    )
  end
  let!(:rent_term) do
    create(
      :rent_term,
      tenancy: tenancy,
      amount_cents: 200_000,
      effective_from: Date.new(2025, 1, 1),
      effective_until: nil
    )
  end
  let(:party) { create(:party, user: user) }
  let!(:tax_profile) do
    create(
      :property_tax_profile,
      property: property,
      tax_year: 2026,
      schedule_e_property_type: "multi_family_residence"
    )
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    create(:tenancy_party, tenancy: tenancy, party: party)
  end

  describe "Core Acceptance Scenarios" do
    it "unpaid rent charge affects receivable/accrual but contributes $0 to Schedule E rents received" do
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      expect(charge_res).to be_success

      result = described_class.call(property: property, tax_year: 2026)

      expect(result.rents_received_cents).to eq(0)
      expect(result.rents_received).to eq(BigDecimal("0.00"))
      expect(result.rents_received_drilldown).to be_empty

      # Verify GL accrual & receivable exist
      ar_acct = user.accounts.find_by!(key: "tenant_receivable")
      income_acct = user.accounts.find_by!(key: "rental_income")
      expect(Accounting::AccountBalanceQuery.call(account: ar_acct)).to eq(200_000)
      expect(Accounting::AccountBalanceQuery.call(account: income_acct)).to eq(200_000)
    end

    it "ordinary tenant receipt contributes to Schedule E rents received" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      rec_res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 75_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )
      expect(rec_res).to be_success

      result = described_class.call(property: property, tax_year: 2026)

      expect(result.rents_received_cents).to eq(75_000)
      expect(result.rents_received).to eq(BigDecimal("750.00"))
      expect(result.rents_received_drilldown.size).to eq(1)
      expect(result.rents_received_drilldown.first.amount_cents).to eq(75_000)
      expect(result.rents_received_drilldown.first.party).to eq(party)
    end

    it "prepayment in December 2026 reports in 2026 and not in 2027 under cash-received policy" do
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 200_000,
        received_on: Date.new(2026, 12, 28),
        payment_method: "zelle"
      )

      # 2026 report
      res2026 = described_class.call(property: property, tax_year: 2026)
      expect(res2026.rents_received_cents).to eq(200_000)

      # 2027 report with 2027 rent charge
      create(:property_tax_profile, property: property, tax_year: 2027, schedule_e_property_type: "multi_family_residence")
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2027, 1, 1)
      )

      res2027 = described_class.call(property: property, tax_year: 2027)
      expect(res2027.rents_received_cents).to eq(0)
    end

    it "overpayment reports full cash received without capping to charges" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 250_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(250_000)
    end

    it "receipt correction and voiding net correctly in rents received" do
      # Receipt $2,000 on Jan 5
      rec_res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 200_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )
      receipt = rec_res.value!.data[:receipt]

      # Correct to $2,100
      Receipts::CorrectService.call(
        receipt: receipt,
        amount_cents: 210_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(210_000)
      expect(result.rents_received_drilldown.size).to eq(3) # original, reversal, replacement
    end

    it "refundable security deposit receipt contributes $0 to Schedule E rents received" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(0)
    end

    it "security deposit refund contributes $0 to Schedule E rents or expenses" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      SecurityDepositTransactions::RefundService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 10)
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(0)
      expect(result.total_expenses_cents).to eq(0)
      expect(result.review_items).to be_empty
    end

    it "security deposit application generates a structured tax review item" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "other",
        description: "Drywall damage",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 15)
      ).value!.data[:charge]

      apply_res = SecurityDepositTransactions::ApplyService.call(
        security_deposit: deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 16)
      )
      entry = apply_res.value!.data[:journal_entry]

      # 1. Unresolved: contributes $0 to rents, present in unresolved_review_items
      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(0)
      expect(result.review_items.size).to eq(1)
      expect(result.unresolved_review_items.size).to eq(1)
      expect(result.review_items.first.resolved?).to be false
      expect(result.review_items.first.amount_cents).to eq(50_000)
      expect(result.review_items.first.reason).to include("Security deposit applied")

      # 2. Resolved with 'include_in_rents': adds $500 to rents, drilldown present, unresolved empty
      resolution = create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry,
        tax_year: 2026,
        treatment: "include_in_rents"
      )

      res_included = described_class.call(property: property, tax_year: 2026)
      expect(res_included.rents_received_cents).to eq(50_000)
      expect(res_included.review_items.size).to eq(1)
      expect(res_included.review_items.first.resolved?).to be true
      expect(res_included.unresolved_review_items).to be_empty
      expect(res_included.rents_received_drilldown.last.label).to include("Security deposit applied (included in rents)")

      # 3. Resolved with 'exclude': contributes $0 to rents, marked resolved, unresolved empty
      resolution.update!(treatment: "exclude")
      res_excluded = described_class.call(property: property, tax_year: 2026)
      expect(res_excluded.rents_received_cents).to eq(0)
      expect(res_excluded.review_items.size).to eq(1)
      expect(res_excluded.review_items.first.resolved?).to be true
      expect(res_excluded.unresolved_review_items).to be_empty

      # 4. Reversal of deposit_applied inherits original resolution automatically
      rev_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 1, 20),
        event_type: "reversal",
        reversal_of: entry,
        source: property
      )
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      # When original was resolved as 'exclude', reversal contributes $0 and net is $0
      res_rev_excluded = described_class.call(property: property, tax_year: 2026)
      expect(res_rev_excluded.rents_received_cents).to eq(0)
      expect(res_rev_excluded.review_items.size).to eq(1) # only original entry is a review item

      # When original is resolved as 'include_in_rents', original is +$500 and reversal is -$500, netting to $0
      resolution.update!(treatment: "include_in_rents")
      res_rev_included = described_class.call(property: property, tax_year: 2026)
      expect(res_rev_included.rents_received_cents).to eq(0)
      expect(res_rev_included.rents_received_drilldown.size).to eq(2)
      expect(res_rev_included.rents_received_drilldown.last.label).to include("Deposit application reversal (included in rents)")
      expect(res_rev_included.rents_received_drilldown.last.amount_cents).to eq(-50_000)
    end
  end

  describe "Expenses Reporting" do
    it "maps every supported expense kind to its respective Schedule E line" do
      expense_kinds = %w[
        advertising
        auto_and_travel
        cleaning_and_maintenance
        commissions
        insurance
        legal_and_professional
        management
        mortgage_interest
        other_interest
        repairs
        supplies
        taxes
        utilities
        other
      ]

      expense_kinds.each_with_index do |kind, i|
        Expenses::CreateService.call(
          property: property,
          expense_kind: kind,
          paid_on: Date.new(2026, 1, i + 1),
          amount_cents: 10_000,
          description: "#{kind.titleize} expense"
        )
      end

      result = described_class.call(property: property, tax_year: 2026)

      expect(result.cents_for(:advertising)).to eq(10_000)
      expect(result.cents_for(:auto_and_travel)).to eq(10_000)
      expect(result.cents_for(:cleaning_and_maintenance)).to eq(10_000)
      expect(result.cents_for(:commissions)).to eq(10_000)
      expect(result.cents_for(:insurance)).to eq(10_000)
      expect(result.cents_for(:legal_and_professional)).to eq(10_000)
      expect(result.cents_for(:management)).to eq(10_000)
      expect(result.cents_for(:mortgage_interest)).to eq(10_000)
      expect(result.cents_for(:other_interest)).to eq(10_000)
      expect(result.cents_for(:repairs)).to eq(10_000)
      expect(result.cents_for(:supplies)).to eq(10_000)
      expect(result.cents_for(:taxes)).to eq(10_000)
      expect(result.cents_for(:utilities)).to eq(10_000)
      expect(result.cents_for(:other)).to eq(10_000)

      expect(result.total_expenses_cents).to eq(140_000)
      expect(result.other_expense_details.size).to eq(1)
      expect(result.other_expense_details.first.description).to eq("Other expense")
    end

    it "reversed expense nets to zero via double-entry postings" do
      exp_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "utilities",
        paid_on: Date.new(2026, 2, 1),
        amount_cents: 30_000
      )
      exp = exp_res.value!.data[:expense]
      Expenses::VoidService.call(expense: exp)

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.cents_for(:utilities)).to eq(0)
      expect(result.total_expenses_cents).to eq(0)
    end

    it "corrected expense nets to replacement amount" do
      exp_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "utilities",
        paid_on: Date.new(2026, 2, 1),
        amount_cents: 30_000
      )
      exp = exp_res.value!.data[:expense]

      Expenses::CorrectService.call(
        expense: exp,
        amount_cents: 35_000
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.cents_for(:utilities)).to eq(35_000)
      expect(result.total_expenses_cents).to eq(35_000)
    end

    it "fails closed on unmapped expense accounts by generating a tax review item instead of defaulting to other, and supports category mapping or exclusion" do
      unmapped_account = user.accounts.create!(
        name: "Capital Improvements",
        key: "expense_capital_improvements",
        account_type: "expense",
        active: true
      )

      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 1),
        description: "New roof installation",
        event_type: "expense_posted"
      )

      create(
        :posting,
        journal_entry: entry,
        account: unmapped_account,
        property: property,
        amount_cents: 800_000
      )
      cash_account = user.accounts.find_by!(key: "cash")
      create(
        :posting,
        journal_entry: entry,
        account: cash_account,
        property: property,
        amount_cents: -800_000
      )

      # 1. Unresolved: Must not be placed in Line 19 Other or counted in total expenses; blocks PDF export
      result = described_class.call(property: property, tax_year: 2026)
      expect(result.cents_for(:other)).to eq(0)
      expect(result.total_expenses_cents).to eq(0)
      expect(result.other_expense_details).to be_empty
      expect(result.review_items.size).to eq(1)
      expect(result.unresolved_review_items.size).to eq(1)
      expect(result.review_items.first.amount_cents).to eq(800_000)
      expect(result.review_items.first.reason).to include("Unmapped expense account 'Capital Improvements'")
      expect(result.review_items.first.expense?).to be true
      expect(result.review_items.first.income?).to be false

      # 2. Reject include_in_rents: An expense cannot be classified as rental income
      invalid_res = PropertyTaxReviewResolution.new(
        property: property,
        journal_entry: entry,
        tax_year: 2026,
        treatment: "include_in_rents"
      )
      expect(invalid_res).not_to be_valid
      expect(invalid_res.errors[:treatment]).to include("cannot include an expense or non-cash/deposit entry in rental income")

      # 3. Resolve with 'map_to_schedule_e_category' -> mapped to repairs (Line 14)
      resolution = create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry,
        tax_year: 2026,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "repairs"
      )

      res_mapped = described_class.call(property: property, tax_year: 2026)
      expect(res_mapped.cents_for(:repairs)).to eq(800_000)
      expect(res_mapped.total_expenses_cents).to eq(800_000)
      expect(res_mapped.expense_drilldown_by_category[:repairs].first.description).to eq("New roof installation")
      expect(res_mapped.review_items.size).to eq(1)
      expect(res_mapped.review_items.first.resolved?).to be true
      expect(res_mapped.unresolved_review_items).to be_empty

      # 4. Resolve with 'map_to_schedule_e_category' -> mapped to other (Line 19)
      resolution.update!(treatment: "map_to_schedule_e_category", schedule_e_category: "other")
      res_other = described_class.call(property: property, tax_year: 2026)
      expect(res_other.cents_for(:other)).to eq(800_000)
      expect(res_other.other_expense_details.size).to eq(1)
      expect(res_other.other_expense_details.first.description).to eq("New roof installation")

      # 5. Resolve with 'exclude' -> omitted from Schedule E expenses, review item marked resolved
      resolution.update!(treatment: "exclude", schedule_e_category: nil)
      res_excluded = described_class.call(property: property, tax_year: 2026)
      expect(res_excluded.total_expenses_cents).to eq(0)
      expect(res_excluded.review_items.size).to eq(1)
      expect(res_excluded.review_items.first.resolved?).to be true
      expect(res_excluded.unresolved_review_items).to be_empty
    end

    it "flags unrecognized financial events touching the property for tax review" do
      cash_account = user.accounts.find_by!(key: "cash")
      liability_account = user.accounts.find_by!(key: "security_deposits_held")

      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 6, 1),
        description: "Mystery transaction",
        event_type: "unrecognized_event",
        source: property
      )

      create(
        :posting,
        journal_entry: entry,
        account: cash_account,
        property: property,
        amount_cents: 120_000
      )
      create(
        :posting,
        journal_entry: entry,
        account: liability_account,
        property: property,
        amount_cents: -120_000
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(0)
      expect(result.review_items.size).to eq(1)
      expect(result.review_items.first.amount_cents).to eq(120_000)
      expect(result.review_items.first.reason).to include("Unrecognized financial event 'unrecognized_event'")
    end

    it "fails closed on unknown events touching mapped expense accounts: unresolved, exclude, include_in_rents, map_to_category" do
      cash_account = user.accounts.find_by!(key: "cash")
      repairs_account = user.accounts.find_by!(key: "expense_repairs")
      equity_account = user.accounts.find_by!(key: "opening_balance_equity")

      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 7, 1),
        description: "Complex settlement with repairs and cash",
        event_type: "complex_settlement",
        source: property
      )
      create(:posting, journal_entry: entry, account: repairs_account, property: property, amount_cents: 10_000) # Dr Repairs $100
      create(:posting, journal_entry: entry, account: cash_account, property: property, amount_cents: 90_000)    # Dr Cash $900
      create(:posting, journal_entry: entry, account: equity_account, property: property, amount_cents: -100_000) # Cr Equity -$1,000

      # 1. Unresolved: fails closed -> Repairs $0, Rents $0, review required
      res_unresolved = described_class.call(property: property, tax_year: 2026)
      expect(res_unresolved.rents_received_cents).to eq(0)
      expect(res_unresolved.cents_for(:repairs)).to eq(0)
      expect(res_unresolved.total_expenses_cents).to eq(0)
      expect(res_unresolved.review_items.size).to eq(1)
      expect(res_unresolved.has_unresolved_reviews?).to be true

      # 2. Resolved with 'exclude' -> Repairs $0, Rents $0, review resolved
      resolution = create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry,
        tax_year: 2026,
        treatment: "exclude"
      )
      res_excluded = described_class.call(property: property, tax_year: 2026)
      expect(res_excluded.rents_received_cents).to eq(0)
      expect(res_excluded.cents_for(:repairs)).to eq(0)
      expect(res_excluded.total_expenses_cents).to eq(0)
      expect(res_excluded.has_unresolved_reviews?).to be false

      # 3. Resolved with 'include_in_rents' -> Rents $900, Repairs $0 (only reviewed income effect)
      resolution.update!(treatment: "include_in_rents")
      res_rents = described_class.call(property: property, tax_year: 2026)
      expect(res_rents.rents_received_cents).to eq(90_000)
      expect(res_rents.cents_for(:repairs)).to eq(0)
      expect(res_rents.total_expenses_cents).to eq(0)
      expect(res_rents.has_unresolved_reviews?).to be false

      # 4. Resolved with 'map_to_schedule_e_category' (repairs) -> Repairs $100, Rents $0 (only reviewed expense effect)
      resolution.update!(treatment: "map_to_schedule_e_category", schedule_e_category: "repairs")
      res_repairs = described_class.call(property: property, tax_year: 2026)
      expect(res_repairs.rents_received_cents).to eq(0)
      expect(res_repairs.cents_for(:repairs)).to eq(10_000)
      expect(res_repairs.total_expenses_cents).to eq(10_000)
      expect(res_repairs.has_unresolved_reviews?).to be false
    end

    it "does not leak mapped expense from reversal of an unresolved review-required event and derives treatment when resolved" do
      repairs_account = user.accounts.find_by!(key: "expense_repairs")
      cash_account = user.accounts.find_by!(key: "cash")
      equity_account = user.accounts.find_by!(key: "opening_balance_equity")

      orig_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 7, 1),
        description: "Complex settlement with repairs and cash",
        event_type: "complex_settlement_reversal_test",
        source: property
      )
      create(:posting, journal_entry: orig_entry, account: repairs_account, property: property, amount_cents: 10_000)
      create(:posting, journal_entry: orig_entry, account: cash_account, property: property, amount_cents: 90_000)
      create(:posting, journal_entry: orig_entry, account: equity_account, property: property, amount_cents: -100_000)

      rev_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 7, 10),
        description: "Reversal of complex settlement",
        event_type: "reversal",
        reversal_of: orig_entry,
        source: property
      )
      create(:posting, journal_entry: rev_entry, account: repairs_account, property: property, amount_cents: -10_000)
      create(:posting, journal_entry: rev_entry, account: cash_account, property: property, amount_cents: -90_000)
      create(:posting, journal_entry: rev_entry, account: equity_account, property: property, amount_cents: 100_000)

      # 1. Unresolved: both original and reversal contribute $0 to repairs
      res_unresolved = described_class.call(property: property, tax_year: 2026)
      expect(res_unresolved.cents_for(:repairs)).to eq(0)
      expect(res_unresolved.total_expenses_cents).to eq(0)
      expect(res_unresolved.rents_received_cents).to eq(0)

      # 2. Resolved original as exclude: repairs remains $0
      resolution = create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: orig_entry,
        tax_year: 2026,
        treatment: "exclude"
      )
      res_excluded = described_class.call(property: property, tax_year: 2026)
      expect(res_excluded.cents_for(:repairs)).to eq(0)
      expect(res_excluded.total_expenses_cents).to eq(0)

      # 3. Resolved original as map_to_schedule_e_category (repairs): +$100 original and -$100 reversal net to $0
      resolution.update!(treatment: "map_to_schedule_e_category", schedule_e_category: "repairs")
      res_repairs = described_class.call(property: property, tax_year: 2026)
      expect(res_repairs.cents_for(:repairs)).to eq(0)
      expect(res_repairs.total_expenses_cents).to eq(0)
      expect(res_repairs.expense_drilldown_by_category[:repairs].size).to eq(2)
      expect(res_repairs.expense_drilldown_by_category[:repairs].map(&:amount_cents)).to contain_exactly(10_000, -10_000)
    end

    it "does not leak mapped expense on cross-year reversal of an unresolved review-required event and derives treatment when resolved" do
      repairs_account = user.accounts.find_by!(key: "expense_repairs")
      cash_account = user.accounts.find_by!(key: "cash")
      equity_account = user.accounts.find_by!(key: "opening_balance_equity")

      orig_2025 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 11, 1),
        description: "2025 Complex settlement with repairs",
        event_type: "complex_settlement_cross_year",
        source: property
      )
      create(:posting, journal_entry: orig_2025, account: repairs_account, property: property, amount_cents: 10_000)
      create(:posting, journal_entry: orig_2025, account: cash_account, property: property, amount_cents: 90_000)
      create(:posting, journal_entry: orig_2025, account: equity_account, property: property, amount_cents: -100_000)

      rev_2026 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 2, 1),
        description: "2026 Reversal of 2025 complex settlement",
        event_type: "reversal",
        reversal_of: orig_2025,
        source: property
      )
      create(:posting, journal_entry: rev_2026, account: repairs_account, property: property, amount_cents: -10_000)
      create(:posting, journal_entry: rev_2026, account: cash_account, property: property, amount_cents: -90_000)
      create(:posting, journal_entry: rev_2026, account: equity_account, property: property, amount_cents: 100_000)

      # 1. Unresolved: 2026 Schedule E Repairs = $0 (not -$100 leak!)
      res_2026_unresolved = described_class.call(property: property, tax_year: 2026)
      expect(res_2026_unresolved.cents_for(:repairs)).to eq(0)
      expect(res_2026_unresolved.total_expenses_cents).to eq(0)
      expect(res_2026_unresolved.review_items.size).to eq(1)
      expect(res_2026_unresolved.review_items.first.unresolved?).to be true

      # 2. Resolve 2025 original as exclude: 2026 Repairs = $0
      resolution = create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: orig_2025,
        tax_year: 2025,
        treatment: "exclude"
      )
      res_2026_excluded = described_class.call(property: property, tax_year: 2026)
      expect(res_2026_excluded.cents_for(:repairs)).to eq(0)
      expect(res_2026_excluded.total_expenses_cents).to eq(0)

      # 3. Resolve 2025 original as map_to_schedule_e_category (repairs):
      # 2025 report has +$100 Repairs, 2026 report has -$100 Repairs cancelling it
      resolution.update!(treatment: "map_to_schedule_e_category", schedule_e_category: "repairs")
      res_2025 = described_class.call(property: property, tax_year: 2025)
      expect(res_2025.cents_for(:repairs)).to eq(10_000)

      res_2026 = described_class.call(property: property, tax_year: 2026)
      expect(res_2026.cents_for(:repairs)).to eq(-10_000)
      expect(res_2026.total_expenses_cents).to eq(-10_000)
      expect(res_2026.expense_drilldown_by_category[:repairs].size).to eq(1)
      expect(res_2026.expense_drilldown_by_category[:repairs].first.amount_cents).to eq(-10_000)
    end

    it "correctly reverses mixed-category expense with both mapped and unmapped postings" do
      unmapped_acct = create(:account, user: user, name: "Consulting", key: "expense_consulting_mixed", account_type: "expense")
      repairs_acct = user.accounts.find_by!(key: "expense_repairs")
      cash_acct = user.accounts.find_by!(key: "cash")

      expense = create(:expense, property: property, expense_kind: "repairs", amount_cents: 15_000)
      orig_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 1),
        description: "Mixed repairs and consulting",
        event_type: "expense_posted",
        source: expense
      )
      create(:posting, journal_entry: orig_entry, property: property, amount_cents: 10_000, account: repairs_acct)
      create(:posting, journal_entry: orig_entry, property: property, amount_cents: 5_000, account: unmapped_acct)
      create(:posting, journal_entry: orig_entry, property: property, amount_cents: -15_000, account: cash_acct)

      # 1. Resolve unmapped portion as "other"
      resolution = create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: orig_entry,
        tax_year: 2026,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "other"
      )

      # Check original projection: Repairs +100, Other +50, Total +150
      res_orig = described_class.call(property: property, tax_year: 2026)
      expect(res_orig.cents_for(:repairs)).to eq(10_000)
      expect(res_orig.cents_for(:other)).to eq(5_000)
      expect(res_orig.total_expenses_cents).to eq(15_000)

      # Reverse the entry
      rev_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 15),
        description: "Reversal of mixed expense",
        event_type: "reversal",
        reversal_of: orig_entry,
        source: expense
      )
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: -10_000, account: repairs_acct)
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: -5_000, account: unmapped_acct)
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: 15_000, account: cash_acct)

      # Both Repairs and Other must independently return to zero!
      res_rev = described_class.call(property: property, tax_year: 2026)
      expect(res_rev.cents_for(:repairs)).to eq(0)
      expect(res_rev.cents_for(:other)).to eq(0)
      expect(res_rev.total_expenses_cents).to eq(0)

      # 2. Test with exclude treatment: mapped Repairs still cancels Repairs, unmapped remains $0
      resolution.update!(treatment: "exclude", schedule_e_category: nil)
      res_exclude = described_class.call(property: property, tax_year: 2026)
      expect(res_exclude.cents_for(:repairs)).to eq(0)
      expect(res_exclude.cents_for(:other)).to eq(0)
      expect(res_exclude.total_expenses_cents).to eq(0)
    end

    it "fails closed when an entry contains multiple distinct unmapped expense accounts" do
      unmapped_acct1 = create(:account, user: user, name: "Landscaping", key: "expense_landscaping_fail_closed", account_type: "expense")
      unmapped_acct2 = create(:account, user: user, name: "Legal", key: "expense_legal_fail_closed", account_type: "expense")
      repairs_acct = user.accounts.find_by!(key: "expense_repairs")
      cash_acct = user.accounts.find_by!(key: "cash")

      expense = create(:expense, property: property, expense_kind: "repairs", amount_cents: 35_000)
      multi_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 1),
        description: "Multi unmapped expense",
        event_type: "expense_posted",
        source: expense
      )
      create(:posting, journal_entry: multi_entry, property: property, amount_cents: 5_000, account: repairs_acct)
      create(:posting, journal_entry: multi_entry, property: property, amount_cents: 10_000, account: unmapped_acct1)
      create(:posting, journal_entry: multi_entry, property: property, amount_cents: 20_000, account: unmapped_acct2)
      create(:posting, journal_entry: multi_entry, property: property, amount_cents: -35_000, account: cash_acct)

      # 1. Before resolution:
      # - Repairs = $50 (mapped leg)
      # - Both unmapped legs contribute $0
      # - Review items has 2 unresolved items (one for Landscaping, one for Legal)
      res_unresolved = described_class.call(property: property, tax_year: 2026)
      expect(res_unresolved.cents_for(:repairs)).to eq(5_000)
      expect(res_unresolved.total_expenses_cents).to eq(5_000)
      expect(res_unresolved.review_items.size).to eq(2)
      expect(res_unresolved.has_unresolved_reviews?).to be true
      expect(res_unresolved.unresolved_review_items.size).to eq(2)

      # 2. Query fails closed on multi-unmapped entries, blocking export
      res_mock = described_class.new(property: property, tax_year: 2026).call
      expect(res_mock.cents_for(:repairs)).to eq(5_000)
      expect(res_mock.has_unresolved_reviews?).to be true

      # 3. Upon reversal, mapped Repairs still cancels to $0, and both unmapped legs remain $0 and unresolved
      rev_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 15),
        description: "Reversal of multi unmapped expense",
        event_type: "reversal",
        reversal_of: multi_entry,
        source: expense
      )
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: -5_000, account: repairs_acct)
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: -10_000, account: unmapped_acct1)
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: -20_000, account: unmapped_acct2)
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: 35_000, account: cash_acct)

      res_rev = described_class.call(property: property, tax_year: 2026)
      expect(res_rev.cents_for(:repairs)).to eq(0)
      expect(res_rev.total_expenses_cents).to eq(0)
      expect(res_rev.has_unresolved_reviews?).to be true
    end

    it "handles multi-property journal entries with one unmapped expense per property independently" do
      prop_b = create(:property, user: user)
      exp = create(:expense, property: property)
      unmapped_acct_a = create(:account, user: user, name: "Landscaping A", key: "expense_landscaping_prop_a", account_type: "expense")
      unmapped_acct_b = create(:account, user: user, name: "Legal B", key: "expense_legal_prop_b", account_type: "expense")
      cash_acct = user.accounts.find_by!(key: "cash")

      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 1),
        description: "Shared vendor invoice across properties",
        event_type: "expense_posted",
        source: exp
      )
      create(:posting, journal_entry: entry, property: property, amount_cents: 10_000, account: unmapped_acct_a)
      create(:posting, journal_entry: entry, property: property, amount_cents: -10_000, account: cash_acct)
      create(:posting, journal_entry: entry, property: prop_b, amount_cents: 20_000, account: unmapped_acct_b)
      create(:posting, journal_entry: entry, property: prop_b, amount_cents: -20_000, account: cash_acct)

      # 1. Before review: Each property has exactly 1 unresolved review item
      res_a_unresolved = described_class.call(property: property, tax_year: 2026)
      expect(res_a_unresolved.review_items.size).to eq(1)
      expect(res_a_unresolved.review_items.first.reason).to include("Landscaping A")
      expect(res_a_unresolved.total_expenses_cents).to eq(0)
      expect(res_a_unresolved.has_unresolved_reviews?).to be true

      res_b_unresolved = described_class.call(property: prop_b, tax_year: 2026)
      expect(res_b_unresolved.review_items.size).to eq(1)
      expect(res_b_unresolved.review_items.first.reason).to include("Legal B")
      expect(res_b_unresolved.total_expenses_cents).to eq(0)
      expect(res_b_unresolved.has_unresolved_reviews?).to be true

      # 2. Resolve Property A as Repairs and Property B as Legal & Professional independently
      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry,
        tax_year: 2026,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "repairs"
      )
      create(
        :property_tax_review_resolution,
        property: prop_b,
        journal_entry: entry,
        tax_year: 2026,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "legal_and_professional"
      )

      res_a = described_class.call(property: property, tax_year: 2026)
      expect(res_a.cents_for(:repairs)).to eq(10_000)
      expect(res_a.cents_for(:legal_and_professional)).to eq(0)
      expect(res_a.total_expenses_cents).to eq(10_000)
      expect(res_a.has_unresolved_reviews?).to be false

      res_b = described_class.call(property: prop_b, tax_year: 2026)
      expect(res_b.cents_for(:repairs)).to eq(0)
      expect(res_b.cents_for(:legal_and_professional)).to eq(20_000)
      expect(res_b.total_expenses_cents).to eq(20_000)
      expect(res_b.has_unresolved_reviews?).to be false

      # 3. Upon reversal, both properties cancel back to $0 independently
      rev_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 15),
        description: "Reversal of shared invoice",
        event_type: "reversal",
        reversal_of: entry,
        source: property
      )
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: -10_000, account: unmapped_acct_a)
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: 10_000, account: cash_acct)
      create(:posting, journal_entry: rev_entry, property: prop_b, amount_cents: -20_000, account: unmapped_acct_b)
      create(:posting, journal_entry: rev_entry, property: prop_b, amount_cents: 20_000, account: cash_acct)

      res_a_rev = described_class.call(property: property, tax_year: 2026)
      expect(res_a_rev.cents_for(:repairs)).to eq(0)
      expect(res_a_rev.total_expenses_cents).to eq(0)
      expect(res_a_rev.has_unresolved_reviews?).to be false

      res_b_rev = described_class.call(property: prop_b, tax_year: 2026)
      expect(res_b_rev.cents_for(:legal_and_professional)).to eq(0)
      expect(res_b_rev.total_expenses_cents).to eq(0)
      expect(res_b_rev.has_unresolved_reviews?).to be false
    end

    it "ignores cash credit outflows and extracts strictly positive cash inflows for include_in_rents" do
      cash_account = user.accounts.find_by!(key: "cash")
      equity_account = user.accounts.find_by!(key: "opening_balance_equity")

      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 7, 15),
        description: "Split cash settlement",
        event_type: "mystery_cash_inflow",
        source: property
      )
      create(:posting, journal_entry: entry, account: cash_account, property: property, amount_cents: 100_000)  # Dr Cash $1,000 (inflow)
      create(:posting, journal_entry: entry, account: cash_account, property: property, amount_cents: -30_000)  # Cr Cash $300 (outflow)
      create(:posting, journal_entry: entry, account: equity_account, property: property, amount_cents: -70_000) # Cr Equity $700

      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry,
        tax_year: 2026,
        treatment: "include_in_rents"
      )

      result = described_class.call(property: property, tax_year: 2026)
      # Must extract only the $1,000 cash inflow, never summing abs(-$300) to get $1,300
      expect(result.rents_received_cents).to eq(100_000)
    end

    it "deterministically extracts cash inflow amount for multi-posting unknown events regardless of posting insertion order" do
      cash_account = user.accounts.find_by!(key: "cash")
      repairs_account = user.accounts.find_by!(key: "expense_repairs")
      equity_account = user.accounts.find_by!(key: "opening_balance_equity")

      # Case A: Postings created in order [Expense $100, Cash $900, Equity -$1,000]
      entry_a = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 7, 1),
        description: "3-posting unknown event A",
        event_type: "complex_settlement",
        source: property
      )
      create(:posting, journal_entry: entry_a, account: repairs_account, property: property, amount_cents: 10_000) # $100
      create(:posting, journal_entry: entry_a, account: cash_account, property: property, amount_cents: 90_000)    # $900
      create(:posting, journal_entry: entry_a, account: equity_account, property: property, amount_cents: -100_000) # -$1,000

      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry_a,
        tax_year: 2026,
        treatment: "include_in_rents"
      )

      result_a = described_class.call(property: property, tax_year: 2026)
      expect(result_a.rents_received_cents).to eq(90_000) # $900 from Cash leg, NEVER $100 or $1,000

      # Case B: Postings created in reverse order [Equity -$1,000, Expense $100, Cash $900]
      entry_b = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 8, 1),
        description: "3-posting unknown event B",
        event_type: "complex_settlement",
        source: user
      )
      create(:posting, journal_entry: entry_b, account: equity_account, property: property, amount_cents: -100_000) # -$1,000
      create(:posting, journal_entry: entry_b, account: repairs_account, property: property, amount_cents: 10_000) # $100
      create(:posting, journal_entry: entry_b, account: cash_account, property: property, amount_cents: 90_000)    # $900

      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry_b,
        tax_year: 2026,
        treatment: "include_in_rents"
      )

      result_b = described_class.call(property: property, tax_year: 2026)
      # Total rents: entry_a ($900) + entry_b ($900) = $1,800 (180_000 cents)
      expect(result_b.rents_received_cents).to eq(180_000)
    end

    it "flags receipt events with mismatched source_type for tax review without counting toward rents" do
      cash_account = user.accounts.find_by!(key: "cash")
      income_account = user.accounts.find_by!(key: "rental_income")

      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 5, 1),
        source: party,
        description: "Payment from party model rather than receipt",
        event_type: "receipt_posted"
      )
      create(
        :posting,
        journal_entry: entry,
        account: cash_account,
        property: property,
        amount_cents: 100_000
      )
      create(
        :posting,
        journal_entry: entry,
        account: income_account,
        property: property,
        amount_cents: -100_000
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(0)
      expect(result.review_items.size).to eq(1)
      expect(result.review_items.first.reason).to include("Unrecognized source type 'Party'")
    end
  end

  describe "Multi-Property & Year Isolation" do
    it "isolates transactions between properties" do
      prop2 = create(:property, user: user)
      unit2 = create(:rentable_unit, property: prop2)
      tenancy2 = create(:tenancy, rentable_unit: unit2)
      create(:tenancy_party, tenancy: tenancy2, party: party)
      create(:property_tax_profile, property: prop2, tax_year: 2026, schedule_e_property_type: "single_family_residence")

      # Property 1 activity
      Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount_cents: 200_000, received_on: Date.new(2026, 1, 5), payment_method: "check")
      Expenses::CreateService.call(property: property, expense_kind: "utilities", paid_on: Date.new(2026, 1, 10), amount_cents: 30_000)

      # Property 2 activity
      Receipts::CreateService.call(tenancy: tenancy2, payer_party: party, amount_cents: 150_000, received_on: Date.new(2026, 1, 5), payment_method: "check")
      Expenses::CreateService.call(property: prop2, expense_kind: "utilities", paid_on: Date.new(2026, 1, 10), amount_cents: 20_000)

      res1 = described_class.call(property: property, tax_year: 2026)
      expect(res1.rents_received_cents).to eq(200_000)
      expect(res1.cents_for(:utilities)).to eq(30_000)

      res2 = described_class.call(property: prop2, tax_year: 2026)
      expect(res2.rents_received_cents).to eq(150_000)
      expect(res2.cents_for(:utilities)).to eq(20_000)
    end

    it "returns :tax_profile_required status when profile is missing" do
      result = described_class.call(property: property, tax_year: 2024)
      expect(result.status).to eq(:tax_profile_required)
      expect(result.tax_profile).to be_nil
      expect(result.tax_profile_configured?).to be false
    end

    it "handles nil property safely" do
      result = described_class.call(property: nil)
      expect(result.status).to eq(:tax_profile_required)
      expect(result.rents_received_cents).to eq(0)
    end

    it "strictly validates explicit tax years and raises ArgumentError on invalid years" do
      expect {
        described_class.call(property: property, tax_year: 2100)
      }.to raise_error(ArgumentError, /Invalid tax year 2100/)

      expect {
        described_class.call(property: property, tax_year: "invalid_year")
      }.to raise_error(ArgumentError, /Invalid tax year "invalid_year"/)

      # Nil tax_year defaults to current year
      result_default = described_class.call(property: property, tax_year: nil)
      expect(result_default.tax_year).to eq(Date.current.year)
    end

    it "handles reversal of an unknown cash entry resolved as include_in_rents" do
      cash_account = user.accounts.find_by!(key: "cash")
      equity_account = user.accounts.find_by!(key: "opening_balance_equity")

      orig_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 1),
        description: "Original cash inflow",
        event_type: "mystery_cash",
        source: property
      )
      create(:posting, journal_entry: orig_entry, account: cash_account, property: property, amount_cents: 50_000)
      create(:posting, journal_entry: orig_entry, account: equity_account, property: property, amount_cents: -50_000)

      rev_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 10),
        description: "Reversal of cash inflow",
        event_type: "reversal",
        reversal_of: orig_entry,
        source: property
      )
      create(:posting, journal_entry: rev_entry, account: cash_account, property: property, amount_cents: -50_000)
      create(:posting, journal_entry: rev_entry, account: equity_account, property: property, amount_cents: 50_000)

      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: orig_entry,
        tax_year: 2026,
        treatment: "include_in_rents"
      )

      res = described_class.call(property: property, tax_year: 2026)
      expect(res.rents_received_cents).to eq(0)
      expect(res.rents_received_drilldown.last.reversal).to be true
      expect(res.rents_received_drilldown.last.amount_cents).to eq(-50_000)
    end

    it "handles cross-year reversal of an unknown cash entry resolved as include_in_rents" do
      cash_account = user.accounts.find_by!(key: "cash")
      equity_account = user.accounts.find_by!(key: "opening_balance_equity")

      orig_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 10, 1),
        description: "Original 2025 cash inflow",
        event_type: "mystery_cash",
        source: property
      )
      create(:posting, journal_entry: orig_entry, account: cash_account, property: property, amount_cents: 50_000)
      create(:posting, journal_entry: orig_entry, account: equity_account, property: property, amount_cents: -50_000)

      rev_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 3, 15),
        description: "2026 reversal of 2025 cash inflow",
        event_type: "reversal",
        reversal_of: orig_entry,
        source: property
      )
      create(:posting, journal_entry: rev_entry, account: cash_account, property: property, amount_cents: -50_000)
      create(:posting, journal_entry: rev_entry, account: equity_account, property: property, amount_cents: 50_000)

      # 1. Unresolved: 2026 report generates review item pointing to 2025 original
      res_unresolved = described_class.call(property: property, tax_year: 2026)
      expect(res_unresolved.review_items.size).to eq(1)
      expect(res_unresolved.review_items.first.resolution_target).to eq(orig_entry)
      expect(res_unresolved.review_items.first.cross_year_reversal?).to be true

      # 2. Resolved in 2025: 2026 derives -$500 to cancel original effect
      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: orig_entry,
        tax_year: 2025,
        treatment: "include_in_rents"
      )

      res_2026 = described_class.call(property: property, tax_year: 2026)
      expect(res_2026.rents_received_cents).to eq(-50_000)
      expect(res_2026.rents_received_drilldown.last.reversal).to be true
      expect(res_2026.review_items.size).to eq(1)
      expect(res_2026.review_items.first.resolved?).to be true
      expect(res_2026.review_items.first.treatment).to eq("include_in_rents")
    end

    it "handles unknown non-cash events for tax review amount calculation" do
      asset_account = create(:account, user: user, name: "Equipment", key: "asset_equipment", account_type: "asset")
      equity_account = user.accounts.find_by!(key: "opening_balance_equity")

      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 5, 1),
        description: "Non-cash barter",
        event_type: "barter_deal",
        source: property
      )
      create(:posting, journal_entry: entry, account: asset_account, property: property, amount_cents: 75_000)
      create(:posting, journal_entry: entry, account: equity_account, property: property, amount_cents: -75_000)

      res = described_class.call(property: property, tax_year: 2026)
      expect(res.review_items.size).to eq(1)
      expect(res.review_items.first.amount_cents).to eq(75_000)
    end

    it "falls back to entry description when source description is blank" do
      expense = create(:expense, property: property, description: nil, expense_kind: "repairs", amount_cents: 12_000)
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 6, 1),
        description: "Direct journal entry expense",
        event_type: "expense_posted",
        source: expense
      )
      create(:posting, journal_entry: entry, account: user.accounts.find_by!(key: "expense_repairs"), property: property, amount_cents: 12_000)
      create(:posting, journal_entry: entry, account: user.accounts.find_by!(key: "cash"), property: property, amount_cents: -12_000)

      res = described_class.call(property: property, tax_year: 2026)
      expect(res.expense_drilldown_by_category[:repairs].first.description).to eq("Direct journal entry expense")
    end

    it "populates other_expense_details for other category expenses" do
      other_account = user.accounts.find_by!(key: "expense_other")
      exp = create(:expense, property: property, expense_kind: "other", amount_cents: 10_000, description: "Trash hauling")
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 6, 15),
        description: "Trash hauling",
        event_type: "expense_posted",
        source: exp
      )
      create(:posting, journal_entry: entry, account: other_account, property: property, amount_cents: 10_000)
      create(:posting, journal_entry: entry, account: user.accounts.find_by!(key: "cash"), property: property, amount_cents: -10_000)

      res = described_class.call(property: property, tax_year: 2026)
      expect(res.other_expense_details.size).to eq(1)
      expect(res.other_expense_details.first.description).to eq("Trash hauling")
      expect(res.other_expense_details.first.amount_cents).to eq(10_000)
    end

    it "classifies review items as :expense when entry only touches expense accounts without cash or deposit" do
      exp_acc = user.accounts.find_by!(key: "expense_repairs")
      payable_acc = create(:account, user: user, name: "Contractor Payable", key: "liability_contractor", account_type: "liability")

      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 7, 20),
        description: "Contractor accrual",
        event_type: "vendor_invoice",
        source: property
      )
      create(:posting, journal_entry: entry, account: exp_acc, property: property, amount_cents: 45_000)
      create(:posting, journal_entry: entry, account: payable_acc, property: property, amount_cents: -45_000)

      res = described_class.call(property: property, tax_year: 2026)
      expect(res.review_items.size).to eq(1)
      expect(res.review_items.first.expense?).to be true
      expect(res.review_items.first.income?).to be false
    end

    it "derives party from tenancy when posting party is nil for included review items" do
      cash_account = user.accounts.find_by!(key: "cash")
      equity_account = user.accounts.find_by!(key: "opening_balance_equity")

      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 8, 1),
        description: "Direct tenancy cash receipt",
        event_type: "tenancy_cash_inflow",
        source: property
      )
      create(:posting, journal_entry: entry, account: cash_account, property: property, tenancy: tenancy, party: nil, amount_cents: 80_000)
      create(:posting, journal_entry: entry, account: equity_account, property: property, tenancy: tenancy, party: nil, amount_cents: -80_000)

      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry,
        tax_year: 2026,
        treatment: "include_in_rents"
      )

      res = described_class.call(property: property, tax_year: 2026)
      expect(res.rents_received_cents).to eq(80_000)
      expect(res.rents_received_drilldown.first.party).to eq(party)
    end

    it "formats review item reason for unmapped expense accounts" do
      expense = create(:expense, property: property, expense_kind: "other", amount_cents: 5_000)
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 8, 15),
        description: "Custom hauling expense",
        event_type: "expense_posted",
        source: expense
      )
      unmapped_acct = create(:account, user: user, name: "Special Hauling", key: "expense_special_hauling", account_type: "expense")
      create(:posting, journal_entry: entry, account: unmapped_acct, property: property, amount_cents: 5_000)

      res = described_class.call(property: property, tax_year: 2026)
      expect(res.review_items.first.reason).to include("Special Hauling")
    end
  end

  describe "Reversal Lineage and Cross-Year Reversals" do
    it "inherits tax treatment on cross-year deposit_applied reversal" do
      # 2025: Deposit applied for $500
      entry_2025 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 11, 1),
        event_type: "deposit_applied",
        source: property
      )
      create(:posting, journal_entry: entry_2025, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: entry_2025, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      # Resolved in 2025 as include_in_rents
      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry_2025,
        tax_year: 2025,
        treatment: "include_in_rents"
      )

      # 2025 report has +$500
      res_2025 = described_class.call(property: property, tax_year: 2025)
      expect(res_2025.rents_received_cents).to eq(50_000)

      # 2026: Reversal occurs in 2026
      rev_2026 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 2, 1),
        event_type: "reversal",
        reversal_of: entry_2025,
        source: property
      )
      create(:posting, journal_entry: rev_2026, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: rev_2026, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      # 2026 report automatically derives include_in_rents and contributes -$500
      res_2026 = described_class.call(property: property, tax_year: 2026)
      expect(res_2026.rents_received_cents).to eq(-50_000)
      expect(res_2026.rents_received_drilldown.first.label).to include("Deposit application reversal (included in rents)")
      expect(res_2026.rents_received_drilldown.first.amount_cents).to eq(-50_000)
      expect(res_2026.review_items.size).to eq(1)
      expect(res_2026.review_items.first.resolved?).to be true
      expect(res_2026.review_items.first.treatment).to eq("include_in_rents")
    end

    it "inherits category on cross-year unmapped expense reversal" do
      unmapped_acct = create(:account, user: user, name: "Consulting", key: "expense_consulting", account_type: "expense")
      entry_2025 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 12, 15),
        description: "Year-end consulting",
        event_type: "expense_posted",
        source: property
      )
      create(:posting, journal_entry: entry_2025, account: unmapped_acct, property: property, amount_cents: 10_000)

      # Resolved in 2025 mapped to :other
      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry_2025,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "other"
      )

      # 2026: Reversal of 2025 expense
      rev_2026 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 1, 10),
        description: "Reversal of year-end consulting",
        event_type: "reversal",
        reversal_of: entry_2025,
        source: property
      )
      create(:posting, journal_entry: rev_2026, account: unmapped_acct, property: property, amount_cents: -10_000)

      res_2026 = described_class.call(property: property, tax_year: 2026)
      expect(res_2026.cents_for(:other)).to eq(-10_000)
      expect(res_2026.total_expenses_cents).to eq(-10_000)
      expect(res_2026.other_expense_details.size).to eq(1)
      expect(res_2026.other_expense_details.first.amount_cents).to eq(-10_000)
      expect(res_2026.review_items.size).to eq(1)
      expect(res_2026.review_items.first.resolved?).to be true
      expect(res_2026.review_items.first.treatment).to eq("map_to_schedule_e_category")
    end

    it "excludes cross-year unmapped expense reversal when original was resolved as exclude" do
      unmapped_acct = create(:account, user: user, name: "Consulting", key: "expense_consulting_2", account_type: "expense")
      entry_2025 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 12, 15),
        description: "Year-end consulting",
        event_type: "expense_posted",
        source: property
      )
      create(:posting, journal_entry: entry_2025, account: unmapped_acct, property: property, amount_cents: 10_000)

      # Resolved in 2025 as exclude
      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry_2025,
        tax_year: 2025,
        treatment: "exclude"
      )

      # 2026: Reversal of 2025 expense
      rev_2026 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 1, 10),
        description: "Reversal of year-end consulting",
        event_type: "reversal",
        reversal_of: entry_2025,
        source: property
      )
      create(:posting, journal_entry: rev_2026, account: unmapped_acct, property: property, amount_cents: -10_000)

      res_2026 = described_class.call(property: property, tax_year: 2026)
      expect(res_2026.total_expenses_cents).to eq(0)
      expect(res_2026.review_items.size).to eq(1)
      expect(res_2026.review_items.first.resolved?).to be true
      expect(res_2026.review_items.first.treatment).to eq("exclude")
    end

    it "defaults tax_year to Date.current.year when omitted" do
      res = described_class.call(property: property)
      expect(res.tax_year).to eq(Date.current.year)
    end

    it "raises ArgumentError when tax_year is out of supported range" do
      expect {
        described_class.call(property: property, tax_year: "invalid")
      }.to raise_error(ArgumentError, /Invalid tax year/)
    end

    it "returns empty_result when property is nil" do
      res = described_class.call(property: nil, tax_year: 2026)
      expect(res.rents_received_cents).to eq(0)
      expect(res.total_expenses_cents).to eq(0)
      expect(res.status).to eq(:tax_profile_required)
    end

    it "maps same-year unmapped expense when resolved as map_to_schedule_e_category" do
      expense = create(:expense, property: property, expense_kind: "other", amount_cents: 8_000)
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 9, 1),
        description: "Special equipment rental",
        event_type: "expense_posted",
        source: expense
      )
      unmapped_acct = create(:account, user: user, name: "Equipment Rental", key: "expense_equip_rental", account_type: "expense")
      create(:posting, journal_entry: entry, account: unmapped_acct, property: property, amount_cents: 8_000)

      create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry,
        tax_year: 2026,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "other"
      )

      res = described_class.call(property: property, tax_year: 2026)
      expect(res.cents_for(:other)).to eq(8_000)
      expect(res.total_expenses_cents).to eq(8_000)
      expect(res.review_items.first.resolved?).to be true
    end

    it "handles nil property and default tax year" do
      expect(described_class.call(property: nil).status).to eq(:tax_profile_required)
      expect(described_class.call(property: property).tax_year).to eq(Date.current.year)
    end

    it "flags multiple unmapped expense accounts in a single journal entry" do
      expense = create(:expense, property: property, expense_kind: "other", amount_cents: 12_000)
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 9, 1),
        description: "Multi-unmapped expense",
        event_type: "expense_posted",
        source: expense
      )
      unmapped1 = create(:account, user: user, name: "Misc A", key: "expense_misc_a", account_type: "expense")
      unmapped2 = create(:account, user: user, name: "Misc B", key: "expense_misc_b", account_type: "expense")
      create(:posting, journal_entry: entry, account: unmapped1, property: property, amount_cents: 6_000)
      create(:posting, journal_entry: entry, account: unmapped2, property: property, amount_cents: 6_000)

      res = described_class.call(property: property, tax_year: 2026)
      expect(res.review_items.size).to eq(2)
      expect(res.review_items.first.reason).to include("multiple unmapped expense accounts")
    end

    it "handles receipt_posted with non-Receipt source and cross-year reversal of unresolved event" do
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 4, 1),
        description: "Direct receipt posted",
        event_type: "receipt_posted",
        source: property
      )
      create(:posting, journal_entry: entry, account: user.accounts.find_by!(key: "cash"), property: property, amount_cents: 10_000)

      res = described_class.call(property: property, tax_year: 2026)
      item = res.review_items.find { |i| i.id == entry.id }
      expect(item.reason).to include("Unrecognized source type 'Property' for receipt event")

      # Cross-year reversal of unresolved 2025 event
      orig_2025 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 11, 1),
        description: "2025 unclassified event",
        event_type: "custom_unclassified_2025",
        source: property
      )
      create(:posting, journal_entry: orig_2025, account: user.accounts.find_by!(key: "cash"), property: property, amount_cents: 5_000)

      rev_2026 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 2, 1),
        description: "Reversal of 2025 event",
        event_type: "reversal",
        reversal_of: orig_2025,
        source: property
      )
      create(:posting, journal_entry: rev_2026, account: user.accounts.find_by!(key: "cash"), property: property, amount_cents: -5_000)

      res2 = described_class.call(property: property, tax_year: 2026)
      item_rev = res2.review_items.find { |i| i.id == rev_2026.id }
      expect(item_rev.reason).to include("Reversal of unresolved 2025 event")
    end
  end
end
