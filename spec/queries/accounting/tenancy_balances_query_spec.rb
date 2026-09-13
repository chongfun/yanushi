require "rails_helper"

RSpec.describe Accounting::TenancyBalancesQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit1) { create(:rentable_unit, property: property) }
  let(:unit2) { create(:rentable_unit, property: property) }
  let(:tenancy1) do
    create(:tenancy, rentable_unit: unit1, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
  end
  let!(:rent_term1) do
    create(:rent_term, tenancy: tenancy1, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end
  let(:tenancy2) do
    create(:tenancy, rentable_unit: unit2, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
  end
  let!(:rent_term2) do
    create(:rent_term, tenancy: tenancy2, amount_cents: 120_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end
  let(:party) { create(:party, user: user) }

  let(:other_user) { create(:user) }
  let(:other_property) { create(:property, user: other_user) }
  let(:other_unit) { create(:rentable_unit, property: other_property) }
  let(:other_tenancy) do
    create(:tenancy, rentable_unit: other_unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
  end
  let!(:other_rent_term) do
    create(:rent_term, tenancy: other_tenancy, amount_cents: 300_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
  end

  describe ".call" do
    it "returns empty hash for empty or nil tenancies" do
      expect(described_class.call(tenancies: [])).to eq({})
      expect(described_class.call(tenancies: nil)).to eq({})
    end

    it "batches balances for multiple tenancies and matches TenancyBalanceQuery" do
      # Tenancy 1: Charge $2,000, Receipt $500 => $1,500 due
      Charges::CreateService.call(
        tenancy: tenancy1,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      Receipts::CreateService.call(
        tenancy: tenancy1,
        payer_party: party,
        amount_cents: 50_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "cash"
      )

      # Tenancy 2: Charge $1,200, Receipt $1,200 => $0
      Charges::CreateService.call(
        tenancy: tenancy2,
        charge_kind: "rent",
        amount_cents: 120_000,
        charge_date: Date.new(2026, 1, 1)
      )
      Receipts::CreateService.call(
        tenancy: tenancy2,
        payer_party: party,
        amount_cents: 120_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "cash"
      )

      result = described_class.call(tenancies: [ tenancy1, tenancy2 ])

      expect(result).to eq(
        tenancy1.id => 150_000,
        tenancy2.id => 0
      )

      expect(result[tenancy1.id]).to eq(
        Accounting::TenancyBalanceQuery.balance_cents_as_of(tenancy: tenancy1)
      )
      expect(result[tenancy2.id]).to eq(
        Accounting::TenancyBalanceQuery.balance_cents_as_of(tenancy: tenancy2)
      )
    end

    it "respects as_of date boundary" do
      Charges::CreateService.call(
        tenancy: tenancy1,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      Charges::CreateService.call(
        tenancy: tenancy1,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 2, 1)
      )

      result_jan = described_class.call(tenancies: [ tenancy1 ], as_of: Date.new(2026, 1, 15))
      expect(result_jan[tenancy1.id]).to eq(200_000)

      result_feb = described_class.call(tenancies: [ tenancy1 ], as_of: Date.new(2026, 2, 15))
      expect(result_feb[tenancy1.id]).to eq(400_000)
    end

    it "isolates tenancies across different users" do
      Charges::CreateService.call(
        tenancy: tenancy1,
        charge_kind: "rent",
        amount_cents: 100_000,
        charge_date: Date.new(2026, 1, 1)
      )
      Charges::CreateService.call(
        tenancy: other_tenancy,
        charge_kind: "rent",
        amount_cents: 300_000,
        charge_date: Date.new(2026, 1, 1)
      )

      user_result = described_class.call(tenancies: [ tenancy1 ])
      expect(user_result).to eq(tenancy1.id => 100_000)

      other_result = described_class.call(tenancies: [ other_tenancy ])
      expect(other_result).to eq(other_tenancy.id => 300_000)
    end

    it "handles blank, string, time, and invalid date formats for as_of" do
      Charges::CreateService.call(
        tenancy: tenancy1,
        charge_kind: "rent",
        amount_cents: 100_000,
        charge_date: Date.new(2026, 1, 1)
      )

      expect(described_class.call(tenancies: [ tenancy1 ], as_of: "")[tenancy1.id]).to eq(100_000)
      expect(described_class.call(tenancies: [ tenancy1 ], as_of: "2026-01-15")[tenancy1.id]).to eq(100_000)
      expect(described_class.call(tenancies: [ tenancy1 ], as_of: Time.new(2026, 1, 15))[tenancy1.id]).to eq(100_000)
      expect(described_class.call(tenancies: [ tenancy1 ], as_of: DateTime.new(2026, 1, 15))[tenancy1.id]).to eq(100_000)
      expect(described_class.call(tenancies: [ tenancy1 ], as_of: "invalid-date")[tenancy1.id]).to eq(100_000)
    end

    it "excludes future-dated postings by default matching TenancyBalanceQuery" do
      Charges::CreateService.call(
        tenancy: tenancy1,
        charge_kind: "late_fee",
        amount_cents: 50_000,
        charge_date: Date.current - 5.days
      )
      Charges::CreateService.call(
        tenancy: tenancy1,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current + 1.month
      )

      default_batch_balance = described_class.call(tenancies: [ tenancy1 ])[tenancy1.id]
      single_query_balance = Accounting::TenancyBalanceQuery.balance_cents_as_of(tenancy: tenancy1)

      expect(default_batch_balance).to eq(50_000)
      expect(default_batch_balance).to eq(single_query_balance)
    end
  end
end
