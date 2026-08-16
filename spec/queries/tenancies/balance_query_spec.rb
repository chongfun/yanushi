require "rails_helper"

RSpec.describe Tenancies::BalanceQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party) { create(:party, user: user) }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.new(2026, 1, 1),
      termination_date: Date.new(2026, 12, 31)
    )
  end
  let!(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant") }
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 150_000,
      effective_from: Date.new(2026, 1, 1),
      effective_until: Date.new(2026, 12, 31)
    )
  end

  describe ".call and instance methods" do
    it "returns 0 for tenancy with no postings" do
      expect(described_class.call(tenancy: tenancy)).to eq(0)
      expect(described_class.new(tenancy: tenancy).balance_cents_as_of).to eq(0)
    end

    it "reflects positive balance when charges are posted (debits to receivable)" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 150_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1),
        service_period_start: Date.new(2026, 1, 1),
        service_period_end: Date.new(2026, 1, 31)
      )

      query = described_class.new(tenancy: tenancy)
      expect(query.balance_cents_as_of).to eq(150_000)
      expect(query.balance_as_of).to eq(1500.0)
    end

    it "reflects settled balance when payment offsets charges" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 150_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1),
        service_period_start: Date.new(2026, 1, 1),
        service_period_end: Date.new(2026, 1, 31)
      )

      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 150_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "other"
      )

      query = described_class.new(tenancy: tenancy)
      expect(query.balance_cents_as_of).to eq(0)
      expect(query.balance_as_of).to eq(0)
    end

    it "reflects negative balance on overpayment / credit balance" do
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 50_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "other"
      )

      query = described_class.new(tenancy: tenancy)
      expect(query.balance_cents_as_of).to eq(-50_000)
      expect(query.balance_as_of).to eq(-500.0)
    end

    it "respects as_of date filtering" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 100_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1),
        service_period_start: Date.new(2026, 1, 1),
        service_period_end: Date.new(2026, 1, 31)
      )

      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 100_000,
        charge_date: Date.new(2026, 2, 1),
        due_on: Date.new(2026, 2, 1),
        service_period_start: Date.new(2026, 2, 1),
        service_period_end: Date.new(2026, 2, 28)
      )

      query = described_class.new(tenancy: tenancy)
      expect(query.balance_cents_as_of(Date.new(2026, 1, 15))).to eq(100_000)
      expect(query.balance_cents_as_of(Date.new(2026, 2, 15))).to eq(200_000)
    end

    it "reflects voided charges through reversal entries" do
      charge_result = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.new(2026, 1, 10)
      )
      charge = charge_result.value!.data[:charge]

      expect(described_class.call(tenancy: tenancy)).to eq(50.0)

      Charges::VoidService.call(charge: charge, occurred_on: Date.new(2026, 1, 12))
      expect(described_class.call(tenancy: tenancy)).to eq(0)
    end

    it "supports current_balance and as_of in class call" do
      query = described_class.new(tenancy: tenancy)
      expect(query.current_balance).to eq(0)
      expect(described_class.call(tenancy: tenancy, as_of: Date.yesterday)).to eq(0)
    end

    it "returns 0 if tenant_receivable account is missing" do
      allow(tenancy).to receive(:accounting_user).and_return(nil)
      query = described_class.new(tenancy: tenancy)
      expect(query.balance_cents_as_of).to eq(0)
    end
  end
end
