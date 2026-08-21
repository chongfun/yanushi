require "rails_helper"

RSpec.describe Accounting::TenancyBalanceQuery do
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

  describe ".call and instance methods" do
    it "calculates current balance and balance_as_of from tenant_receivable postings" do
      # 2026-01-01: Rent $2,000
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      # 2026-01-05: Payment $750
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 75_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "cash"
      )

      # 2026-01-10: Late fee $50
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2026, 1, 10)
      )

      # 2026-01-15: Apply deposit $500
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 100_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 2)
      )
      fee_charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 1)
      ).value!.data[:charge]
      SecurityDepositTransactions::ApplyService.call(
        security_deposit: deposit,
        charge: fee_charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 15)
      )

      # Total: 2000 - 750 + 50 + 500 (fee) - 500 (deposit applied) = 1300.00
      query = described_class.new(tenancy: tenancy)
      expect(query.balance_cents_as_of(Date.new(2026, 1, 31))).to eq(130_000)
      expect(query.balance_as_of(Date.new(2026, 1, 31))).to eq(BigDecimal("1300.00"))
      expect(query.current_balance).to eq(BigDecimal("1300.00"))
      expect(described_class.call(tenancy: tenancy, as_of: Date.new(2026, 1, 31))).to eq(BigDecimal("1300.00"))
    end

    it "handles nil tenancy or missing account gracefully" do
      expect(described_class.call(tenancy: nil)).to eq(BigDecimal("0.0"))
    end
  end
end
