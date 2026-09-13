require "rails_helper"

RSpec.describe Accounting::PortfolioSummaryQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  let(:property1) { create(:property, user: user, address: "123 Main St") }
  let(:unit1) { create(:rentable_unit, property: property1, name: "Unit 1") }
  let(:tenancy1) { create(:tenancy, rentable_unit: unit1, commencement_date: Date.new(2025, 1, 1)) }
  let!(:rent_term1) { create(:rent_term, tenancy: tenancy1, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1)) }

  let(:property2) { create(:property, user: user, address: "456 Oak Ave") }
  let(:unit2) { create(:rentable_unit, property: property2, name: "Unit 2") }
  let(:tenancy2) { create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2025, 1, 1)) }
  let!(:rent_term2) { create(:rent_term, tenancy: tenancy2, amount_cents: 150_000, effective_from: Date.new(2025, 1, 1)) }

  let(:party) { create(:party, user: user, display_name: "Tenant Alice") }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
  end

  def build_portfolio_activity
    # Property 1: $2,000 rent charge (income recognized, no cash)
    Charges::CreateService.call(
      tenancy: tenancy1,
      charge_kind: "rent",
      amount_cents: 200_000,
      charge_date: Date.new(2026, 1, 1)
    )

    # Property 2: $1,500 receipt (cash in, no income recognized)
    Receipts::CreateService.call(
      tenancy: tenancy2,
      payer_party: party,
      amount_cents: 150_000,
      received_on: Date.new(2026, 1, 5),
      payment_method: "check"
    )

    # Property 1: $400 repairs (operating expense, cash out)
    Expenses::CreateService.call(
      property: property1,
      expense_kind: "repairs",
      paid_on: Date.new(2026, 1, 10),
      amount_cents: 40_000
    )

    # Property 2: $900 mortgage interest (non-operating expense, cash out)
    Expenses::CreateService.call(
      property: property2,
      expense_kind: "mortgage_interest",
      paid_on: Date.new(2026, 1, 12),
      amount_cents: 90_000
    )
  end

  describe ".call" do
    it "totals income, expenses, net income, and net cash movement across every property" do
      build_portfolio_activity

      summary = described_class.call(user: user, year: 2026)

      expect(summary.income_recognized_cents).to eq(200_000)
      expect(summary.operating_expenses_cents).to eq(40_000)
      expect(summary.interest_expenses_cents).to eq(90_000)
      expect(summary.total_expenses_cents).to eq(130_000)
      expect(summary.net_income_cents).to eq(70_000)
      expect(summary.net_cash_movement_cents).to eq(20_000) # 150_000 - 40_000 - 90_000
      expect(summary.date_range.year).to eq(2026)
      expect(summary.property_id).to be_nil
    end

    it "narrows the totals to one property" do
      build_portfolio_activity

      summary = described_class.call(user: user, property_id: property1.id, year: 2026)

      expect(summary.property_id).to eq(property1.id)
      expect(summary.income_recognized_cents).to eq(200_000)
      expect(summary.operating_expenses_cents).to eq(40_000)
      expect(summary.interest_expenses_cents).to eq(0)
      expect(summary.total_expenses_cents).to eq(40_000)
      expect(summary.net_income_cents).to eq(160_000)
      expect(summary.net_cash_movement_cents).to eq(-40_000)
    end

    it "matches the property summary for a single property" do
      build_portfolio_activity

      portfolio = described_class.call(user: user, property_id: property2.id, year: 2026)
      per_property = Accounting::PropertySummaryQuery.call(property: property2, year: 2026)

      expect(portfolio.income_recognized_cents).to eq(per_property.income_recognized_cents)
      expect(portfolio.operating_expenses_cents).to eq(per_property.operating_expenses_cents)
      expect(portfolio.interest_expenses_cents).to eq(per_property.interest_expenses_cents)
      expect(portfolio.total_expenses_cents).to eq(per_property.total_expenses_cents)
      expect(portfolio.net_income_cents).to eq(per_property.net_income_cents)
      expect(portfolio.net_cash_movement_cents).to eq(per_property.net_cash_movement_cents)
    end

    it "restricts totals to the selected period" do
      Expenses::CreateService.call(
        property: property1,
        expense_kind: "repairs",
        paid_on: Date.new(2025, 5, 1),
        amount_cents: 11_000
      )
      Expenses::CreateService.call(
        property: property1,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 5, 1),
        amount_cents: 22_000
      )

      expect(described_class.call(user: user, year: 2025).total_expenses_cents).to eq(11_000)
      expect(described_class.call(user: user, year: 2026).total_expenses_cents).to eq(22_000)

      custom = described_class.call(user: user, from: "2025-01-01", through: "2026-12-31")
      expect(custom.total_expenses_cents).to eq(33_000)

      through_only = described_class.call(user: user, through: Date.new(2025, 12, 31))
      expect(through_only.total_expenses_cents).to eq(11_000)
    end

    it "nets out reversals from corrections and voids" do
      result = Expenses::CreateService.call(
        property: property1,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 50_000
      )
      expense = result.value!.data[:expense]

      Expenses::CorrectService.call(
        expense: expense,
        expense_kind: "repairs",
        amount_cents: 60_000,
        paid_on: Date.new(2026, 1, 10)
      )

      summary = described_class.call(user: user, year: 2026)
      expect(summary.total_expenses_cents).to eq(60_000)
      expect(summary.net_cash_movement_cents).to eq(-60_000)
    end

    it "enforces cross-user isolation" do
      other_property = create(:property, user: other_user)
      Expenses::CreateService.call(
        property: other_property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 77_000
      )

      summary = described_class.call(user: user, year: 2026)
      expect(summary.total_expenses_cents).to eq(0)

      # Another user's property_id yields zeroes rather than their figures.
      isolated = described_class.call(user: user, property_id: other_property.id, year: 2026)
      expect(isolated.total_expenses_cents).to eq(0)
    end

    it "returns zeroes when the date range is invalid" do
      build_portfolio_activity

      invalid_range = Accounting::DateRange.new(from: Date.new(2026, 12, 31), through: Date.new(2026, 1, 1))
      summary = described_class.call(user: user, date_range: invalid_range)

      expect(summary.income_recognized_cents).to eq(0)
      expect(summary.total_expenses_cents).to eq(0)
      expect(summary.net_income_cents).to eq(0)
      expect(summary.net_cash_movement_cents).to eq(0)
    end

    it "aggregates in SQL without loading postings" do
      build_portfolio_activity

      queries = []
      counter = ->(_name, _started, _finished, _unique_id, payload) {
        queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA CACHE])
      }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        described_class.call(user: user, year: 2026)
      end

      expect(queries.size).to eq(1)
      expect(queries.first).to include("SUM")
      expect(queries.none? { |sql| sql.include?('SELECT "postings".*') }).to be true
    end
  end
end
