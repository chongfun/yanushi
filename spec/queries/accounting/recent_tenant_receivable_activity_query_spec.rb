require "rails_helper"

RSpec.describe Accounting::RecentTenantReceivableActivityQuery do
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

  describe ".call and running balance derivation" do
    it "fetches only the latest N rows and derives correct running balances from prior history" do
      # Create 7 historical transactions chronologically:
      # 1. Jan 1: Rent +$2,000 (bal: 2,000)
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 1, 1))
      # 2. Jan 5: Payment -$2,000 (bal: 0)
      Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount_cents: 200_000, received_on: Date.new(2026, 1, 5), payment_method: "check")
      # 3. Feb 1: Rent +$2,000 (bal: 2,000)
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 2, 1))
      # 4. Feb 5: Payment -$1,500 (bal: 500)
      Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount_cents: 150_000, received_on: Date.new(2026, 2, 5), payment_method: "check")
      # 5. Feb 10: Late Fee +$50 (bal: 550)
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "late_fee", amount_cents: 5_000, charge_date: Date.new(2026, 2, 10))
      # 6. Mar 1: Rent +$2,000 (bal: 2,550)
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 3, 1))
      # 7. Mar 5: Payment -$2,550 (bal: 0)
      Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount_cents: 255_000, received_on: Date.new(2026, 3, 5), payment_method: "check")

      # Fetch recent 4 rows as of 2026-03-31
      rows = described_class.call(tenancy: tenancy, limit: 4, as_of: Date.new(2026, 3, 31))

      # Exactly 4 rows returned in descending order (Mar 5, Mar 1, Feb 10, Feb 5)
      expect(rows.size).to eq(4)

      # Row 0: Mar 5 Payment -$2,550 -> running balance: $0.00
      expect(rows[0].occurred_on).to eq(Date.new(2026, 3, 5))
      expect(rows[0].kind).to eq("payment")
      expect(rows[0].amount_cents).to eq(-255_000)
      expect(rows[0].running_balance_cents).to eq(0)

      # Row 1: Mar 1 Rent +$2,000 -> running balance: $2,550.00
      expect(rows[1].occurred_on).to eq(Date.new(2026, 3, 1))
      expect(rows[1].kind).to eq("rent")
      expect(rows[1].amount_cents).to eq(200_000)
      expect(rows[1].running_balance_cents).to eq(255_000)

      # Row 2: Feb 10 Late fee +$50 -> running balance: $550.00
      expect(rows[2].occurred_on).to eq(Date.new(2026, 2, 10))
      expect(rows[2].kind).to eq("late_fee")
      expect(rows[2].amount_cents).to eq(5_000)
      expect(rows[2].running_balance_cents).to eq(55_000)

      # Row 3: Feb 5 Payment -$1,500 -> running balance: $500.00
      expect(rows[3].occurred_on).to eq(Date.new(2026, 2, 5))
      expect(rows[3].kind).to eq("payment")
      expect(rows[3].amount_cents).to eq(-150_000)
      expect(rows[3].running_balance_cents).to eq(50_000)
    end

    it "excludes transactions dated after as_of" do
      # Past charge on Jan 1
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 1, 1))
      # Future charge on Dec 1
      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 12, 1))

      rows = described_class.call(tenancy: tenancy, limit: 5, as_of: Date.new(2026, 6, 1))
      expect(rows.size).to eq(1)
      expect(rows.first.occurred_on).to eq(Date.new(2026, 1, 1))
      expect(rows.first.running_balance_cents).to eq(200_000)

      all_rows = described_class.call(tenancy: tenancy, limit: 5, as_of: nil)
      expect(all_rows.size).to eq(2)
    end

    it "returns empty array when tenancy is nil or unprovisioned" do
      expect(described_class.call(tenancy: nil)).to eq([])

      unprovisioned_user = create(:user)
      unprovisioned_prop = create(:property, user: unprovisioned_user)
      unprovisioned_unit = create(:rentable_unit, property: unprovisioned_prop)
      unprovisioned_tenancy = create(:tenancy, rentable_unit: unprovisioned_unit)
      unprovisioned_user.accounts.destroy_all

      expect(described_class.call(tenancy: unprovisioned_tenancy)).to eq([])
    end
  end
end
