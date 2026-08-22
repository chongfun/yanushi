require "rails_helper"

RSpec.describe Accounting::TenancyActivityQuery do
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

  describe ".call" do
    it "returns all activity rows associated with the tenancy" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 200_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "cash"
      )

      rows = described_class.call(tenancy: tenancy, year: 2026)
      expect(rows.size).to eq(2)
      expect(rows.map(&:kind)).to eq(%w[payment rent])
    end

    it "excludes activity from other tenancies" do
      unit2 = create(:rentable_unit, property: property)
      tenancy2 = create(:tenancy, rentable_unit: unit2, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
      create(:rent_term, tenancy: tenancy2, amount_cents: 150_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)

      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 1, 1))
      Charges::CreateService.call(tenancy: tenancy2, charge_kind: "rent", amount_cents: 150_000, charge_date: Date.new(2026, 1, 1))

      rows = described_class.call(tenancy: tenancy, year: 2026)
      expect(rows.size).to eq(1)
      expect(rows.first.amount_cents).to eq(200_000)
    end

    it "handles nil tenancy and partial date range filters" do
      expect(described_class.call(tenancy: nil)).to eq([])

      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 1, 1))

      from_only = described_class.call(tenancy: tenancy, from: Date.new(2026, 1, 1))
      expect(from_only.size).to eq(1)

      from_only_dr = described_class.call(tenancy: tenancy, date_range: Accounting::DateRange.new(from: Date.new(2026, 1, 1), through: nil))
      expect(from_only_dr.size).to eq(1)

      through_only = described_class.call(tenancy: tenancy, through: Date.new(2026, 12, 31))
      expect(through_only.size).to eq(1)

      all_time = described_class.call(tenancy: tenancy, date_range: Accounting::DateRange.new(from: nil, through: nil))
      expect(all_time.size).to eq(1)

      invalid = described_class.call(tenancy: tenancy, date_range: Accounting::DateRange.parse(from: "2026-12-31", through: "2026-01-01"))
      expect(invalid).to eq([])
    end
  end
end
