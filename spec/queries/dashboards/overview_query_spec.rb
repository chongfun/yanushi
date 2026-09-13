require "rails_helper"

RSpec.describe Dashboards::OverviewQuery do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  let(:property) { create(:property, user: user, address: "123 Main St") }
  let(:unit1) { create(:rentable_unit, property: property, name: "Unit 1") }
  let(:unit2) { create(:rentable_unit, property: property, name: "Unit 2") }

  let(:tenancy) do
    create(:tenancy, rentable_unit: unit1, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
  end
  let!(:rent_term) do
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end
  let(:party) { create(:party, user: user, display_name: "Jane Smith") }

  # The overdue rule keys off today; pin the clock and restore it afterwards.
  around do |example|
    travel_to(Date.new(2026, 9, 15)) { example.run }
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
    create(:tenancy_party, tenancy: tenancy, party: party)
  end

  describe ".call" do
    it "returns an OverviewResult with all sections populated" do
      unit2 # instantiate vacant unit2

      # Create an attention item: $350 charged, and overdue past the grace period
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 35_000,
        charge_date: Date.current - 10.days
      )

      result = described_class.call(user: user)

      expect(result).to be_a(Dashboards::OverviewQuery::OverviewResult)
      expect(result.attention_items.size).to eq(1)
      expect(result.attention_items.first.kind).to eq(:balance_due)

      expect(result.portfolio_summary.properties_count).to eq(1)
      expect(result.portfolio_summary.total_units_count).to eq(2)
      expect(result.portfolio_summary.occupied_units_count).to eq(1)
      expect(result.portfolio_summary.outstanding_balances_cents).to eq(35_000)

      expect(result.properties.size).to eq(1)
      prop_row = result.properties.first
      expect(prop_row.property).to eq(property)
      expect(prop_row.occupied_units_count).to eq(1)
      expect(prop_row.total_units_count).to eq(2)
      expect(prop_row.balance_cents).to eq(35_000)

      expect(result.recent_activity.size).to eq(1)
      expect(result.recent_activity.first.amount_cents).to eq(35_000)
    end

    it "handles zero state when user has no properties or activity" do
      result = described_class.call(user: other_user)

      expect(result.attention_items).to eq([])
      expect(result.portfolio_summary.properties_count).to eq(0)
      expect(result.properties).to eq([])
      expect(result.recent_activity).to eq([])
    end

    it "isolates all overview data strictly to the requested user" do
      other_property = create(:property, user: other_user)
      create(:rentable_unit, property: other_property)

      user_result = described_class.call(user: user)
      other_result = described_class.call(user: other_user)

      expect(user_result.properties.map(&:property)).to eq([ property ])
      expect(other_result.properties.map(&:property)).to eq([ other_property ])
    end

    it "handles nil user cleanly with empty result" do
      result = described_class.call(user: nil)
      expect(result.attention_items).to eq([])
      expect(result.portfolio_summary.properties_count).to eq(0)
      expect(result.properties).to eq([])
      expect(result.recent_activity).to eq([])
    end

    it "calculates PropertyRow#balance as BigDecimal dollars" do
      row = Dashboards::OverviewQuery::PropertyRow.new(
        property: property,
        occupied_units_count: 1,
        total_units_count: 1,
        balance_cents: 35_000
      )
      expect(row.balance).to eq(BigDecimal("350.00"))
    end

    it "does not net debt on one unit against credit on another unit for property balance" do
      # Unit 1 tenancy owes $500 (Charge $500)
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 50_000,
        charge_date: Date.current
      )

      # Unit 2 tenancy has $500 credit (Receipt $500 without prior charge)
      tenancy2 = create(:tenancy, rentable_unit: unit2, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1))
      create(:tenancy_party, tenancy: tenancy2, party: party)
      Receipts::CreateService.call(
        tenancy: tenancy2,
        payer_party: party,
        amount_cents: 50_000,
        received_on: Date.current,
        payment_method: "cash"
      )

      result = described_class.call(user: user)
      prop_row = result.properties.first
      expect(prop_row.balance_cents).to eq(50_000)
    end

    it "excludes inactive historical units from property unit counts" do
      unit2 # active unit 2
      create(:rentable_unit, property: property, name: "Historical Unit", active: false)

      result = described_class.call(user: user)
      prop_row = result.properties.first
      expect(prop_row.total_units_count).to eq(2)
    end

    it "handles property with zero units" do
      empty_property = create(:property, user: user, address: "Empty Property")
      result = described_class.call(user: user)
      empty_row = result.properties.find { |p| p.property == empty_property }
      expect(empty_row.total_units_count).to eq(0)
      expect(empty_row.occupied_units_count).to eq(0)
      expect(empty_row.balance_cents).to eq(0)
    end

    it "surfaces credit when property contains only tenant credits" do
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 886_000,
        received_on: Date.current,
        payment_method: "check"
      )

      result = described_class.call(user: user)
      prop_row = result.properties.first
      expect(prop_row.balance_cents).to eq(-886_000)
    end

    it "invokes Accounting::TenancyBalancesQuery only once per dashboard computation" do
      allow(Accounting::TenancyBalancesQuery).to receive(:call).and_call_original

      described_class.call(user: user)

      expect(Accounting::TenancyBalancesQuery).to have_received(:call).once
    end

    it "splits overdue from not-yet-due money in one batched pass" do
      allow(Tenancies::OverdueQuery).to receive(:call).and_call_original

      described_class.call(user: user)

      expect(Tenancies::OverdueQuery).to have_received(:call).once
    end

    it "keeps a balance that is still inside its grace period out of the attention queue" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 35_000,
        charge_date: Date.current
      )

      result = described_class.call(user: user)

      expect(result.attention_items).to eq([])
      expect(result.portfolio_summary.outstanding_balances_cents).to eq(35_000)
      expect(result.properties.first.balance_cents).to eq(35_000)
    end
  end
end
