require "rails_helper"

RSpec.describe Accounting::PropertySummaryQuery do
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

  describe ".call and calculations" do
    it "computes cash in/out, accrual income, operating expenses, and as-of balances" do
      # 1. Rent charge: +$2,000 AR, -$2,000 Income (Accrual income recognized: $2,000, Cash: $0)
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      # 2. Payment: +$1,500 Cash, -$1,500 AR (Cash in: $1,500)
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 150_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "zelle"
      )

      # 3. Expense: +$300 Repairs Expense, -$300 Cash (Operating expense: $300, Cash out: $300)
      Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 30_000
      )

      # 4. Deposit received: +$1,000 Cash, -$1,000 Security Deposits Held (Cash in: $1,000, Deposit liability: $1,000)
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 100_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 2)
      )

      summary = described_class.call(property: property, year: 2026)

      # Cash movement
      expect(summary.net_cash_movement_cents).to eq(220_000) # $1,500 rent + $1,000 deposit - $300 repairs
      expect(summary.net_cash_movement).to eq(BigDecimal("2200.00"))

      # Accrual income & expense
      expect(summary.income_recognized_cents).to eq(200_000) # Only $2,000 rent charge, NOT deposit!
      expect(summary.operating_expenses_cents).to eq(30_000)
      expect(summary.net_operating_income_cents).to eq(170_000)

      # Closing balances
      expect(summary.tenant_receivable_cents).to eq(50_000) # $2,000 charge - $1,500 payment = $500
      expect(summary.security_deposits_held_cents).to eq(100_000) # $1,000 deposit held
      expect(summary.income_recognized).to eq(BigDecimal("2000.00"))
      expect(summary.operating_expenses).to eq(BigDecimal("300.00"))
      expect(summary.net_operating_income).to eq(BigDecimal("1700.00"))
      expect(summary.tenant_receivable).to eq(BigDecimal("500.00"))
      expect(summary.security_deposits_held).to eq(BigDecimal("1000.00"))
    end

    it "calculates exact net cash when receipt corrections occur without gross reversal distortion" do
      # 1. Original Receipt: $1,500
      rec_res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 150_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )
      receipt = rec_res.value!.data[:receipt]

      # 2. Correct to $1,600 (Reverses $1,500 and creates $1,600)
      Receipts::CorrectService.call(
        receipt: receipt,
        amount_cents: 160_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      summary = described_class.call(property: property, year: 2026)
      expect(summary.net_cash_movement_cents).to eq(160_000)
      expect(summary.net_cash_movement).to eq(BigDecimal("1600.00"))
    end

    it "bounds from-only queries to today so future-dated entries are excluded and reconcile with closing balances" do
      # Past charge on Jan 1
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current - 10.days
      )

      # Future charge 10 days in the future
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current + 10.days
      )

      from_only_summary = described_class.call(property: property, from: Date.current - 20.days)

      # Period income should only include the past charge up to Date.current
      expect(from_only_summary.income_recognized_cents).to eq(200_000)
      expect(from_only_summary.tenant_receivable_cents).to eq(200_000)
    end

    it "calculates negative income recognized in reversal-only periods" do
      # 2025: Late fee charged ($50)
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2025, 12, 1)
      )
      charge = charge_res.value!.data[:charge]

      # 2026: Waived/voided in 2026
      Charges::VoidService.call(
        charge: charge,
        occurred_on: Date.new(2026, 1, 15)
      )

      summary_2026 = described_class.call(property: property, year: 2026)
      expect(summary_2026.income_recognized_cents).to eq(-5_000)
      expect(summary_2026.income_recognized).to eq(BigDecimal("-50.00"))
    end

    it "handles reversals correctly without double counting" do
      # Expense created and voided
      exp_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 30_000
      )
      exp = exp_res.value!.data[:expense]
      Expenses::VoidService.call(expense: exp)

      summary = described_class.call(property: property, year: 2026)
      expect(summary.operating_expenses_cents).to eq(0)
      expect(summary.net_cash_movement_cents).to eq(0)
    end

    it "handles nil property and partial date range filters" do
      nil_summary = described_class.call(property: nil)
      expect(nil_summary.net_cash_movement_cents).to eq(0)

      Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 30_000
      )

      from_only = described_class.call(property: property, from: Date.new(2026, 1, 1))
      expect(from_only.operating_expenses_cents).to eq(30_000)

      from_only_dr = described_class.call(property: property, date_range: Accounting::DateRange.new(from: Date.new(2026, 1, 1), through: nil))
      expect(from_only_dr.operating_expenses_cents).to eq(30_000)

      through_only = described_class.call(property: property, through: Date.new(2026, 12, 31))
      expect(through_only.operating_expenses_cents).to eq(30_000)

      all_time = described_class.call(property: property, date_range: Accounting::DateRange.new(from: nil, through: nil))
      expect(all_time.operating_expenses_cents).to eq(30_000)

      invalid_summary = described_class.call(
        property: property,
        date_range: Accounting::DateRange.parse(from: "2026-12-31", through: "2026-01-01")
      )
      expect(invalid_summary.operating_expenses_cents).to eq(0)
      expect(invalid_summary.net_cash_movement_cents).to eq(0)
      expect(invalid_summary.tenant_receivable_cents).to eq(0)
      expect(invalid_summary.security_deposits_held_cents).to eq(0)
    end
  end
end
