require "rails_helper"

RSpec.describe Tenancies::StatementCsvService, type: :service do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user, address: "123 Main St") }
  let(:unit) { create(:rentable_unit, property: property, name: "Unit 4B") }
  let(:tenancy) do
    create(:tenancy, :month_to_month, rentable_unit: unit, commencement_date: Date.new(2025, 1, 1))
  end
  let!(:rent_term) do
    create(:rent_term, tenancy: tenancy, amount_cents: 150_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end
  let(:party) { create(:party, user: user, display_name: "Alice Walker") }
  let!(:tenancy_party) do
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant",
      effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end
  let(:date_range) { Accounting::DateRange.new(year: 2026) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  def statement
    Accounting::TenantReceivableActivityQuery.call(tenancy: tenancy, date_range: date_range)
  end

  def charge_rent(cents: 150_000, on: Date.new(2026, 1, 1))
    Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: cents, charge_date: on)
  end

  def parse(csv)
    CSV.parse(csv)
  end

  describe ".call" do
    it "names the tenancy, the period, and the balances above the rows" do
      charge_rent(on: Date.new(2025, 12, 1))
      charge_rent(on: Date.new(2026, 1, 1))
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 50_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      rows = parse(described_class.call(tenancy: tenancy, date_range: date_range, statement: statement))

      expect(rows.first).to eq([ "Tenant account statement" ])
      expect(rows).to include([ "Tenants", "Alice Walker" ])
      expect(rows).to include([ "Unit", unit.display_name ])
      expect(rows).to include([ "Property", "123 Main St" ])
      expect(rows).to include([ "Period", "Calendar year 2026" ])
      expect(rows).to include([ "Opening balance", "$1,500.00" ])
      expect(rows).to include([ "Closing balance", "$2,500.00" ])
    end

    it "writes the rows with their status and running balance" do
      charge_rent(on: Date.new(2026, 1, 1))
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 50_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      rows = parse(described_class.call(tenancy: tenancy, date_range: date_range, statement: statement))
      header_index = rows.index([ "Date", "Activity", "Notes", "Status", "Amount", "Running balance" ])
      data = rows.drop(header_index + 1)

      expect(header_index).to be_present
      expect(data.map(&:first)).to eq([ "2026-01-01", "2026-01-05" ])
      expect(data.map { |row| row[3] }).to eq([ "Active", "Active" ])
      expect(data.map { |row| row[4] }).to eq([ "$1,500.00", "-$500.00" ])
      expect(data.map(&:last)).to eq([ "$1,500.00", "$1,000.00" ])
    end

    it "keeps a waived charge and marks its status so it can be filtered, not lost" do
      late_fee = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2026, 1, 2)
      ).value!.data[:charge]
      Charges::VoidService.call(charge: late_fee, occurred_on: Date.new(2026, 1, 15))

      rows = parse(described_class.call(tenancy: tenancy, date_range: date_range, statement: statement))
      header_index = rows.index([ "Date", "Activity", "Notes", "Status", "Amount", "Running balance" ])
      data = rows.drop(header_index + 1)

      expect(data.size).to eq(2)
      expect(data.map { |row| row[3] }).to include("Voided")
      expect(data.map { |row| row[2] }.any? { |note| note.include?("Waiver") }).to be true
      expect(rows).to include([ "Note", Tenancies::StatementExport::AUDIT_NOTE ])
    end

    it "still names the tenancy and the balances when the period has no activity" do
      rows = parse(described_class.call(tenancy: tenancy, date_range: date_range, statement: statement))

      expect(rows).to include([ "Opening balance", "$0.00" ])
      expect(rows).to include([ "Closing balance", "$0.00" ])
      expect(rows.last).to eq([ "Date", "Activity", "Notes", "Status", "Amount", "Running balance" ])
    end

    it "writes the all-activity log with its participants when given activity rows" do
      charge_rent(on: Date.new(2026, 1, 1))
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 50_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      csv = described_class.call(
        tenancy: tenancy,
        date_range: date_range,
        activity_rows: Accounting::TenancyActivityQuery.call(tenancy: tenancy, date_range: date_range)
      )
      rows = parse(csv)
      header_index = rows.index([ "Date", "Event", "Participant", "Status", "Amount" ])
      data = rows.drop(header_index + 1)

      expect(rows.first).to eq([ "Tenancy financial activity" ])
      expect(rows.none? { |row| row.first == "Opening balance" }).to be true
      expect(data.map { |row| row[2] }).to include("Alice Walker")
      expect(csv).not_to include("−")
    end

    # A spreadsheet evaluates a cell that begins with =, +, -, or @, so any
    # cell carrying a name someone typed has to reach Excel as literal text.
    describe "spreadsheet formula neutralization" do
      it "makes a description that looks like a formula literal text" do
        [ '=HYPERLINK("https://example.invalid","Alice")', "+1+1", "-2+3", "@SUM(A1)" ].each do |payload|
          Charges::CreateService.call(
            tenancy: tenancy,
            charge_kind: "other",
            amount_cents: 1_000,
            charge_date: Date.new(2026, 2, 1),
            description: payload
          )
        end

        csv = described_class.call(tenancy: tenancy, date_range: date_range, statement: statement)
        cells = parse(csv).flatten.compact

        [ "=", "+", "@" ].each do |trigger|
          expect(cells.none? { |cell| cell.start_with?(trigger) }).to be true
        end
        expect(cells).to include("'" + '=HYPERLINK("https://example.invalid","Alice")')
        expect(cells).to include("'@SUM(A1)")
        expect(cells).to include("'-2+3")
      end

      it "makes a payer name and a property address that look like formulas literal text" do
        formula_party = create(:party, user: user, display_name: "=cmd|' /C calc'!A0")
        formula_property = create(:property, user: user, address: "@10 Formula Way")
        formula_unit = create(:rentable_unit, property: formula_property, name: "=Unit")
        formula_tenancy = create(
          :tenancy,
          rentable_unit: formula_unit,
          commencement_date: Date.new(2026, 1, 1),
          termination_date: Date.new(2026, 12, 31),
          agreement_type: "fixed_term"
        )
        create(:tenancy_party, tenancy: formula_tenancy, party: formula_party, role: "tenant", effective_from: Date.new(2026, 1, 1))

        csv = described_class.call(
          tenancy: formula_tenancy,
          date_range: date_range,
          statement: Accounting::TenantReceivableActivityQuery.call(tenancy: formula_tenancy, date_range: date_range)
        )
        cells = parse(csv).flatten.compact

        expect(cells.none? { |cell| cell.start_with?("=", "@") }).to be true
        expect(cells).to include("'=cmd|' /C calc'!A0")
        expect(cells).to include("'@10 Formula Way")
        expect(cells).to include("'#{formula_unit.display_name}")
      end

      it "leaves negative money as a number a spreadsheet can still total" do
        charge_rent(cents: 100_000, on: Date.new(2026, 1, 1))
        Receipts::CreateService.call(
          tenancy: tenancy,
          payer_party: party,
          amount_cents: 40_000,
          received_on: Date.new(2026, 1, 5),
          payment_method: "check"
        )

        csv = described_class.call(tenancy: tenancy, date_range: date_range, statement: statement)

        expect(csv).to include("-$400.00")
        expect(csv).not_to include("'-$400.00")
      end
    end
  end
end
