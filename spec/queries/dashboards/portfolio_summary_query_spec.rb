require "rails_helper"

RSpec.describe Dashboards::PortfolioSummaryQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  let(:property) { create(:property, user: user) }
  let(:unit1) { create(:rentable_unit, property: property, name: "Unit 1") }
  let(:unit2) { create(:rentable_unit, property: property, name: "Unit 2") }

  let(:tenancy) do
    create(:tenancy, rentable_unit: unit1, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
  end
  let!(:rent_term) do
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end
  let(:party) { create(:party, user: user, display_name: "Jane Smith") }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
    create(:tenancy_party, tenancy: tenancy, party: party)
  end

  describe ".call" do
    it "returns zero-summary when user has no properties" do
      summary = described_class.call(user: other_user)

      expect(summary.properties_count).to eq(0)
      expect(summary.total_units_count).to eq(0)
      expect(summary.occupied_units_count).to eq(0)
      expect(summary.vacant_units_count).to eq(0)
      expect(summary.outstanding_balances_cents).to eq(0)
      expect(summary.net_income_cents).to eq(0)
      expect(summary.income_cents).to eq(0)
      expect(summary.expenses_cents).to eq(0)
    end

    it "computes counts, balances, and YTD financial totals" do
      # Make unit1 occupied, unit2 vacant => 1 of 2 occupied
      unit2 # instantiate unit2

      # Post a charge and receipt
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current
      )
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 150_000,
        received_on: Date.current,
        payment_method: "cash"
      )

      # Create an expense
      expense = create(:expense, property: property, amount_cents: 40_000, paid_on: Date.current)
      Expenses::PostService.call(expense: expense)

      summary = described_class.call(user: user)

      expect(summary.properties_count).to eq(1)
      expect(summary.total_units_count).to eq(2)
      expect(summary.occupied_units_count).to eq(1)
      expect(summary.vacant_units_count).to eq(1)
      expect(summary.outstanding_balances_cents).to eq(50_000) # $2000 - $1500 = $500 due
      expect(summary.income_cents).to eq(200_000) # $2000 rent income
      expect(summary.expenses_cents).to eq(40_000) # $400 expense
      expect(summary.net_income_cents).to eq(160_000) # $2000 - $400 = $1600
    end

    it "excludes future-dated postings from YTD totals" do
      # Future-dated charge (e.g. 1 month from now)
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current + 1.month
      )

      summary = described_class.call(user: user)

      expect(summary.income_cents).to eq(0)
      expect(summary.net_income_cents).to eq(0)
    end

    it "isolates portfolio summary strictly to the requested user" do
      other_property = create(:property, user: other_user)
      create(:rentable_unit, property: other_property)

      user_summary = described_class.call(user: user)
      other_summary = described_class.call(user: other_user)

      expect(user_summary.properties_count).to eq(1)
      expect(other_summary.properties_count).to eq(1)
    end

    it "handles nil user cleanly with empty summary" do
      summary = described_class.call(user: nil)
      expect(summary.properties_count).to eq(0)
      expect(summary.outstanding_balances_cents).to eq(0)
      expect(summary.net_income_cents).to eq(0)
    end

    it "calculates summary with open-ended date range" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current
      )

      open_range = Accounting::DateRange.new(through: Date.current)
      summary = described_class.call(user: user, date_range: open_range)
      expect(summary.income_cents).to eq(200_000)

      open_from_range = Accounting::DateRange.new(from: Date.current - 1.month, through: nil)
      summary_from = described_class.call(user: user, date_range: open_from_range)
      expect(summary_from.income_cents).to eq(200_000)
    end

    it "exposes BigDecimal helper methods on PortfolioSummary" do
      summary = Dashboards::PortfolioSummaryQuery::PortfolioSummary.new(
        properties_count: 1,
        occupied_units_count: 1,
        total_units_count: 1,
        vacant_units_count: 0,
        outstanding_balances_cents: 50_000,
        net_income_cents: 160_000,
        income_cents: 200_000,
        expenses_cents: 40_000
      )

      expect(summary.outstanding_balances).to eq(BigDecimal("500.00"))
      expect(summary.net_income).to eq(BigDecimal("1600.00"))
      expect(summary.income).to eq(BigDecimal("2000.00"))
      expect(summary.expenses).to eq(BigDecimal("400.00"))
    end

    it "excludes deactivated historical units from current unit inventory and vacancy" do
      unit2 # active unit 2
      create(:rentable_unit, property: property, name: "Historical Unit", active: false)

      summary = described_class.call(user: user)
      expect(summary.total_units_count).to eq(2)
      expect(summary.occupied_units_count).to eq(1)
      expect(summary.vacant_units_count).to eq(1)
    end

    it "includes positive balances from terminated/past tenancies in outstanding balances" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 80_000,
        charge_date: Date.current - 5.days
      )
      tenancy.update!(termination_date: Date.current - 1.day)

      summary = described_class.call(user: user)
      expect(summary.occupied_units_count).to eq(0)
      expect(summary.outstanding_balances_cents).to eq(80_000)
    end
  end
end
