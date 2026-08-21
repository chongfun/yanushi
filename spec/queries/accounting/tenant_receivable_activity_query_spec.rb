require "rails_helper"

RSpec.describe Accounting::TenantReceivableActivityQuery do
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

  describe ".call and running statement calculations" do
    it "calculates opening balance, running balances, and closing balance correctly" do
      # 2025-12-01: Previous Rent ($2,000) -> Opening balance for 2026 is $2,000
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2025, 12, 1)
      )

      # 2026-01-01: Rent ($2,000) -> Running: 4,000
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      # 2026-01-05: Payment ($2,500) -> Running: 1,500
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 250_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "zelle"
      )

      # 2026-01-10: Late fee ($50) -> Running: 1,550
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2026, 1, 10)
      )

      # 2026-01-15: Apply deposit ($500) -> Running: 1,050
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 100_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 2)
      )
      charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 1)
      ).value!.data[:charge]
      SecurityDepositTransactions::ApplyService.call(
        security_deposit: deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 15)
      )

      statement = described_class.call(
        tenancy: tenancy,
        from: Date.new(2026, 1, 1),
        through: Date.new(2026, 1, 31)
      )

      expect(statement.opening_balance_cents).to eq(200_000) # $2,000 from 2025
      expect(statement.opening_balance).to eq(BigDecimal("2000.00"))

      # Row 1: Jan 1 Rent (+200_000) -> 400_000
      expect(statement.rows[0].occurred_on).to eq(Date.new(2026, 1, 1))
      expect(statement.rows[0].kind).to eq("rent")
      expect(statement.rows[0].amount_cents).to eq(200_000)
      expect(statement.rows[0].running_balance_cents).to eq(400_000)

      # Row 2: Jan 1 Charge (Fee) (+50_000) -> 450_000
      expect(statement.rows[1].occurred_on).to eq(Date.new(2026, 1, 1))
      expect(statement.rows[1].amount_cents).to eq(50_000)
      expect(statement.rows[1].running_balance_cents).to eq(450_000)

      # Row 3: Jan 5 Payment (-250_000) -> 200_000
      expect(statement.rows[2].occurred_on).to eq(Date.new(2026, 1, 5))
      expect(statement.rows[2].kind).to eq("payment")
      expect(statement.rows[2].amount_cents).to eq(-250_000)
      expect(statement.rows[2].running_balance_cents).to eq(200_000)

      # Row 4: Jan 10 Late fee (+5_000) -> 205_000
      expect(statement.rows[3].occurred_on).to eq(Date.new(2026, 1, 10))
      expect(statement.rows[3].kind).to eq("late_fee")
      expect(statement.rows[3].amount_cents).to eq(5_000)
      expect(statement.rows[3].running_balance_cents).to eq(205_000)

      # Row 5: Jan 15 Deposit applied (-50_000) -> 155_000
      expect(statement.rows[4].occurred_on).to eq(Date.new(2026, 1, 15))
      expect(statement.rows[4].kind).to eq("deposit_applied")
      expect(statement.rows[4].amount_cents).to eq(-50_000)
      expect(statement.rows[4].running_balance_cents).to eq(155_000)

      expect(statement.closing_balance_cents).to eq(155_000)
      expect(statement.closing_balance).to eq(BigDecimal("1550.00"))
      expect(statement.rows[0].amount).to eq(BigDecimal("2000.00"))
      expect(statement.rows[0].running_balance).to eq(BigDecimal("4000.00"))
    end

    it "handles nil tenancy, missing account, and partial date ranges" do
      expect(described_class.call(tenancy: nil).rows).to eq([])

      unprovisioned_user = create(:user)
      unprovisioned_prop = create(:property, user: unprovisioned_user)
      unprovisioned_unit = create(:rentable_unit, property: unprovisioned_prop)
      unprovisioned_tenancy = create(:tenancy, rentable_unit: unprovisioned_unit)
      unprovisioned_user.accounts.destroy_all

      expect(described_class.call(tenancy: unprovisioned_tenancy).rows).to eq([])

      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      from_only = described_class.call(tenancy: tenancy, from: Date.new(2026, 1, 1))
      expect(from_only.rows.size).to eq(1)

      from_only_dr = described_class.call(tenancy: tenancy, date_range: Accounting::DateRange.new(from: Date.new(2026, 1, 1), through: nil))
      expect(from_only_dr.rows.size).to eq(1)

      through_only = described_class.call(tenancy: tenancy, through: Date.new(2026, 12, 31))
      expect(through_only.rows.size).to eq(1)

      all_time = described_class.call(tenancy: tenancy, date_range: Accounting::DateRange.new(from: nil, through: nil))
      expect(all_time.rows.size).to eq(1)

      invalid = described_class.call(tenancy: tenancy, date_range: Accounting::DateRange.parse(from: "2026-12-31", through: "2026-01-01"))
      expect(invalid.rows).to eq([])
      expect(invalid.opening_balance_cents).to eq(0)
      expect(invalid.closing_balance_cents).to eq(0)
    end

    it "projects charge waivers with distinct label and lifecycle status" do
      # 1. Late fee charged on Jan 2
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2026, 1, 2)
      )
      late_fee = charge_res.value!.data[:charge]

      # 2. Waive late fee on Jan 15
      Charges::VoidService.call(
        charge: late_fee,
        occurred_on: Date.new(2026, 1, 15)
      )

      statement = described_class.call(tenancy: tenancy, year: 2026)
      expect(statement.rows.size).to eq(2)

      waiver_row = statement.rows.find(&:reversal)
      expect(waiver_row.kind).to eq("waiver")
      expect(waiver_row.label).to eq("Late Fee Waived")
      expect(waiver_row.amount_cents).to eq(-5_000)

      orig_row = statement.rows.find { |r| !r.reversal }
      expect(orig_row.lifecycle_status).to eq(:voided)
      expect(orig_row.voided?).to be true
      expect(orig_row.corrected?).to be false
    end
  end
end
