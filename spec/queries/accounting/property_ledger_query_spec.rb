require "rails_helper"

RSpec.describe Accounting::PropertyLedgerQuery do
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

  describe ".call and instance query" do
    it "returns all property ledger activity rows within the given period" do
      # 2026-01-01: Rent charge ($2,000)
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      # 2026-01-05: Receipt ($2,000)
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 200_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      # 2026-01-10: Expense ($300)
      Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 30_000
      )

      # 2025-12-15: Out of period charge
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2025, 12, 15)
      )

      rows = described_class.call(property: property, year: 2026)
      expect(rows.size).to eq(3)

      # Sorted by occurred_on DESC
      expect(rows.map(&:occurred_on)).to eq([
        Date.new(2026, 1, 10),
        Date.new(2026, 1, 5),
        Date.new(2026, 1, 1)
      ])
      expect(rows.map(&:kind)).to eq(%w[expense payment rent])
    end

    it "includes original, reversal, and replacement rows when corrections occur" do
      # Original payment: $2,000 on Jan 5
      rec_res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 200_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )
      receipt = rec_res.value!.data[:receipt]

      # Corrected to $2,100
      Receipts::CorrectService.call(
        receipt: receipt,
        amount_cents: 210_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      rows = described_class.call(property: property, year: 2026)
      # Must contain 3 rows: replacement, reversal, original
      expect(rows.size).to eq(3)
      expect(rows.count(&:reversal)).to eq(1)

      reversal_row = rows.find(&:reversal)
      expect(reversal_row.amount_cents).to eq(-200_000)

      replacement_row = rows.find { |r| !r.reversal && r.amount_cents == 210_000 }
      expect(replacement_row).to be_present

      original_row = rows.find { |r| !r.reversal && r.amount_cents == 200_000 }
      expect(original_row).to be_present
      expect(original_row.corrected).to be true
      expect(original_row.lifecycle_status).to eq(:corrected)
      expect(original_row.corrected?).to be true
      expect(original_row.voided?).to be false
    end

    it "distinguishes charge waivers from corrections with distinct labels and lifecycle status" do
      # 1. Late fee charged on Jan 2
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2026, 1, 2)
      )
      late_fee = charge_res.value!.data[:charge]

      # 2. Waive the late fee on Jan 15
      Charges::VoidService.call(
        charge: late_fee,
        occurred_on: Date.new(2026, 1, 15)
      )

      rows = described_class.call(property: property, year: 2026)
      expect(rows.size).to eq(2)

      waiver_row = rows.find(&:reversal)
      expect(waiver_row.kind).to eq("waiver")
      expect(waiver_row.label).to eq("Late Fee Waived")
      expect(waiver_row.amount_cents).to eq(-5_000)
      expect(waiver_row.occurred_on).to eq(Date.new(2026, 1, 15))

      original_row = rows.find { |r| !r.reversal }
      expect(original_row.kind).to eq("late_fee")
      expect(original_row.label).to eq("Late Fee")
      expect(original_row.lifecycle_status).to eq(:voided)
      expect(original_row.voided?).to be true
      expect(original_row.corrected?).to be false
    end

    it "preserves active status for historical 2025 report when waiver occurs in 2026" do
      # 1. Late fee charged on Dec 15, 2025
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2025, 12, 15)
      )
      late_fee = charge_res.value!.data[:charge]

      # 2. Waive the late fee in 2026
      Charges::VoidService.call(
        charge: late_fee,
        occurred_on: Date.new(2026, 1, 10)
      )

      # 2025 report: charge was not yet waived on Dec 31, 2025
      rows_2025 = described_class.call(property: property, year: 2025)
      expect(rows_2025.size).to eq(1)
      expect(rows_2025.first.kind).to eq("late_fee")
      expect(rows_2025.first.amount_cents).to eq(5_000)
      expect(rows_2025.first.lifecycle_status).to eq(:active)
      expect(rows_2025.first.active?).to be true
      expect(rows_2025.first.voided?).to be false

      # 2026 report: contains the waiver row
      rows_2026 = described_class.call(property: property, year: 2026)
      expect(rows_2026.size).to eq(1)
      expect(rows_2026.first.kind).to eq("waiver")
      expect(rows_2026.first.amount_cents).to eq(-5_000)
      expect(rows_2026.first.label).to eq("Late Fee Waived")
    end

    it "isolates multifamily properties" do
      prop2 = create(:property, user: user)
      unit2 = create(:rentable_unit, property: prop2)
      tenancy2 = create(:tenancy, rentable_unit: unit2, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
      create(:rent_term, tenancy: tenancy2, amount_cents: 150_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)

      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 1, 1))
      Charges::CreateService.call(tenancy: tenancy2, charge_kind: "rent", amount_cents: 150_000, charge_date: Date.new(2026, 1, 1))

      prop1_rows = described_class.call(property: property, year: 2026)
      expect(prop1_rows.size).to eq(1)
      expect(prop1_rows.first.amount_cents).to eq(200_000)

      prop2_rows = described_class.call(property: prop2, year: 2026)
      expect(prop2_rows.size).to eq(1)
      expect(prop2_rows.first.amount_cents).to eq(150_000)
    end

    it "handles nil property and partial date range filters" do
      expect(described_class.call(property: nil)).to eq([])

      Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: 200_000, charge_date: Date.new(2026, 1, 1))

      from_only = described_class.call(property: property, from: Date.new(2026, 1, 1))
      expect(from_only.size).to eq(1)

      from_only_dr = described_class.call(property: property, date_range: Accounting::DateRange.new(from: Date.new(2026, 1, 1), through: nil))
      expect(from_only_dr.size).to eq(1)

      through_only = described_class.call(property: property, through: Date.new(2026, 12, 31))
      expect(through_only.size).to eq(1)

      invalid = described_class.call(property: property, date_range: Accounting::DateRange.parse(from: "2026-12-31", through: "2026-01-01"))
      expect(invalid).to eq([])
    end

    it "avoids N+1 Party queries when projecting multiple receipts" do
      5.times do |i|
        p = create(:party, user: user, display_name: "Tenant #{i}")
        Receipts::CreateService.call(
          tenancy: tenancy,
          payer_party: p,
          amount_cents: 100_000,
          received_on: Date.new(2026, 1, i + 1),
          payment_method: "check"
        )
      end

      # Preloaded property query
      rows = described_class.call(property: property, year: 2026)
      expect(rows.size).to eq(5)

      queries = []
      counter = ->(_name, _started, _finished, _unique_id, payload) {
        queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA CACHE])
      }

      # Iterating rows and reading row.party must trigger 0 additional queries
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        parties = rows.map { |r| r.party&.display_name }
        expect(parties.compact.size).to eq(5)
      end

      expect(queries).to be_empty
    end
  end
end
