require "rails_helper"

RSpec.describe Accounting::AccountActivityQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil) }
  let!(:rent_term) do
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end
  let(:party) { create(:party, user: user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  let(:ar_account) { user.accounts.find_by!(key: "tenant_receivable") }
  let(:cash_account) { user.accounts.find_by!(key: "cash") }

  describe ".call and result structure" do
    it "returns chronologically ordered postings with opening and running balances" do
      # 2025-12-01: Prior rent charge ($2,000)
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2025, 12, 1))

      # 2026-01-01: Rent charge ($2,000)
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 1, 1))

      # 2026-01-15: Payment ($1,500)
      Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount_cents: 150_000, received_on: Date.new(2026, 1, 15), payment_method: "zelle")

      query = described_class.new(
        account: ar_account,
        from: Date.new(2026, 1, 1),
        through: Date.new(2026, 1, 31)
      )
      result = query.call

      expect(result.opening_natural_balance_cents).to eq(200_000)
      expect(result.rows.size).to eq(2)

      # Row 1: Jan 1 Rent (+200_000) -> Running: 400_000
      row1 = result.rows[0]
      expect(row1.occurred_on).to eq(Date.new(2026, 1, 1))
      expect(row1.debit_cents).to eq(200_000)
      expect(row1.credit_cents).to eq(0)
      expect(row1.running_natural_balance_cents).to eq(400_000)

      # Row 2: Jan 15 Payment (-150_000) -> Running: 250_000
      row2 = result.rows[1]
      expect(row2.occurred_on).to eq(Date.new(2026, 1, 15))
      expect(row2.debit_cents).to eq(0)
      expect(row2.credit_cents).to eq(150_000)
      expect(row2.running_natural_balance_cents).to eq(250_000)

      expect(result.closing_natural_balance_cents).to eq(250_000)
    end

    it "handles liability/income credit-normal running balances" do
      # Jan 1: Rent charge -> Rental Income credited 200,000 (-200,000 raw, +200,000 natural)
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 1, 1))

      income_account = user.accounts.find_by!(key: "rental_income")
      query = described_class.new(account: income_account, from: Date.new(2026, 1, 1), through: Date.new(2026, 1, 31))
      result = query.call

      expect(result.opening_natural_balance_cents).to eq(0)
      expect(result.rows.size).to eq(1)
      row = result.rows[0]
      expect(row.credit_cents).to eq(200_000)
      expect(row.debit_cents).to eq(0)
      expect(row.running_natural_balance_cents).to eq(200_000)
      expect(result.closing_natural_balance_cents).to eq(200_000)
    end

    it "filters by dimensions" do
      unit2 = create(:rentable_unit, property: property)
      tenancy2 = create(:tenancy, rentable_unit: unit2, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
      create(:rent_term, tenancy: tenancy2, amount_cents: 150_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)

      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 100_000, charge_date: Date.new(2026, 1, 1))
      Charges::CreateService.call(tenancy: tenancy2, charge_kind: "rent", amount_cents: 150_000, charge_date: Date.new(2026, 1, 1))

      t1_result = described_class.new(account: ar_account, tenancy: tenancy, from: "2026-01-01", through: "2026-01-31").call
      expect(t1_result.rows.size).to eq(1)
      expect(t1_result.rows.first.debit_cents).to eq(100_000)
    end

    it "handles nil account gracefully" do
      result = described_class.new(account: nil).call
      expect(result.opening_natural_balance_cents).to eq(0)
      expect(result.closing_natural_balance_cents).to eq(0)
      expect(result.rows).to eq([])
    end

    it "filters by property, unit, party, and partial date ranges" do
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 100_000, charge_date: Date.new(2026, 1, 1))
      Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount_cents: 100_000, received_on: Date.new(2026, 1, 5), payment_method: "check")

      prop_res = described_class.call(account: ar_account, property: property, year: 2026)
      expect(prop_res.rows.size).to eq(2)

      unit_res = described_class.call(account: ar_account, rentable_unit: unit, year: 2026)
      expect(unit_res.rows.size).to eq(2)

      party_res = described_class.call(account: ar_account, party: party, year: 2026)
      expect(party_res.rows.size).to eq(1)

      from_only = described_class.call(account: ar_account, from: Date.new(2026, 1, 1))
      expect(from_only.rows.size).to eq(2)

      through_only = described_class.call(account: ar_account, through: Date.new(2026, 12, 31))
      expect(through_only.rows.size).to eq(2)

      all_time = described_class.call(account: ar_account, date_range: Accounting::DateRange.new(from: nil, through: nil))
      expect(all_time.rows.size).to eq(2)
    end

    it "preloads associations to avoid N+1 queries when accessing row attributes" do
      # Create 10 distinct charges and 10 receipts with different units, tenancies, and parties
      10.times do
        u = create(:rentable_unit, property: property)
        t = create(:tenancy, rentable_unit: u, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
        create(:rent_term, tenancy: t, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
        p = create(:party, user: user)
        create(:tenancy_party, tenancy: t, party: p)
        Charges::CreateService.call(tenancy: t, charge_kind: "rent", amount_cents: 100_000, charge_date: Date.new(2026, 1, 1))
        Receipts::CreateService.call(tenancy: t, payer_party: p, amount_cents: 100_000, received_on: Date.new(2026, 1, 5), payment_method: "check")
      end

      # Track queries during query execution and iteration
      queries = []
      counter = ->(_name, _started, _finished, _unique_id, payload) {
        queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA CACHE])
      }

      result = nil
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        result = described_class.new(account: ar_account, year: 2026).call
        result.rows.each do |row|
          row.property&.address
          row.rentable_unit&.name
          row.tenancy&.id
          row.party&.display_name
          row.journal_entry.description
        end
      end

      expect(result.rows.size).to eq(20)
      # 1 query for opening balance, 1 for postings, 5 preloading queries for associations = ~7 total queries
      expect(queries.size).to be <= 10
    end
  end
end
