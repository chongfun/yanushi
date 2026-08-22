require "rails_helper"

RSpec.describe Accounting::AccountBalanceQuery do
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
  let(:income_account) { user.accounts.find_by!(key: "rental_income") }
  let(:cash_account) { user.accounts.find_by!(key: "cash") }
  let(:deposit_account) { user.accounts.find_by!(key: "security_deposits_held") }

  describe ".call and instance methods" do
    it "calculates natural and raw balances for asset (debit normal) accounts" do
      # Rent charge posted on Jan 1: Dr Tenant Receivable 200,000 / Cr Rental Income -200,000
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      query = described_class.new(account: ar_account)
      expect(query.raw_balance_cents).to eq(200_000)
      expect(query.natural_balance_cents).to eq(200_000)
      expect(query.natural_balance).to eq(BigDecimal("2000.00"))
      expect(query.balance_cents).to eq(200_000)
      expect(query.balance).to eq(BigDecimal("2000.00"))
    end

    it "calculates natural and raw balances for income and liability (credit normal) accounts" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      query = described_class.new(account: income_account)
      # Raw balance is negative in DB (-200_000), natural balance is positive (200_000)
      expect(query.raw_balance_cents).to eq(-200_000)
      expect(query.natural_balance_cents).to eq(200_000)
      expect(query.natural_balance).to eq(BigDecimal("2000.00"))
    end

    it "respects as_of date filters strictly based on journal_entry.occurred_on" do
      # Event 1 on Jan 1
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      # Event 2 on Feb 1
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 2, 1)
      )

      jan_query = described_class.new(account: ar_account, as_of: Date.new(2026, 1, 15))
      expect(jan_query.natural_balance_cents).to eq(200_000)

      feb_query = described_class.new(account: ar_account, as_of: Date.new(2026, 2, 15))
      expect(feb_query.natural_balance_cents).to eq(400_000)
    end

    it "filters by dimensions (property, unit, tenancy, party)" do
      unit2 = create(:rentable_unit, property: property)
      tenancy2 = create(:tenancy, rentable_unit: unit2, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
      create(:rent_term, tenancy: tenancy2, amount_cents: 150_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)

      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 100_000, charge_date: Date.new(2026, 1, 1))
      Charges::CreateService.call(tenancy: tenancy2, charge_kind: "rent", amount_cents: 150_000, charge_date: Date.new(2026, 1, 1))

      prop_query = described_class.new(account: ar_account, property: property)
      expect(prop_query.natural_balance_cents).to eq(250_000)

      t1_query = described_class.new(account: ar_account, tenancy: tenancy)
      expect(t1_query.natural_balance_cents).to eq(100_000)

      t2_query = described_class.new(account: ar_account, tenancy: tenancy2)
      expect(t2_query.natural_balance_cents).to eq(150_000)

      u1_query = described_class.new(account: ar_account, rentable_unit: unit)
      expect(u1_query.natural_balance_cents).to eq(100_000)

      # Payment with party
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 40_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      party_query = described_class.new(account: ar_account, party: party)
      expect(party_query.natural_balance_cents).to eq(-40_000)
    end

    it "parses as_of dates from Strings, Times, and Dates" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 100_000,
        charge_date: Date.new(2026, 1, 1)
      )

      expect(described_class.call(account: ar_account, as_of: "2026-01-05")).to eq(100_000)
      expect(described_class.call(account: ar_account, as_of: Time.zone.local(2026, 1, 5))).to eq(100_000)
      expect(described_class.call(account: ar_account, as_of: nil)).to eq(100_000)
    end

    it "handles nil account gracefully" do
      query = described_class.new(account: nil)
      expect(query.raw_balance_cents).to eq(0)
      expect(query.natural_balance_cents).to eq(0)
      expect(query.natural_balance).to eq(0.0)
    end
  end
end
