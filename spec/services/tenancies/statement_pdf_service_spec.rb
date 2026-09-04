require "rails_helper"

RSpec.describe Tenancies::StatementPdfService, type: :service do
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

  def statement(range = date_range)
    Accounting::TenantReceivableActivityQuery.call(tenancy: tenancy, date_range: range)
  end

  def charge_rent(cents: 150_000, on: Date.new(2026, 1, 1))
    Charges::CreateService.call(tenancy: tenancy, charge_kind: "rent", amount_cents: cents, charge_date: on)
  end

  describe ".call" do
    it "renders a real PDF for the account view" do
      charge_rent
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 100_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      pdf = described_class.call(tenancy: tenancy, date_range: date_range, statement: statement)

      expect(pdf).to start_with("%PDF-")
      expect(pdf.bytesize).to be > 1_000
    end

    it "renders a real PDF for the all-activity view" do
      charge_rent

      pdf = described_class.call(
        tenancy: tenancy,
        date_range: date_range,
        activity_rows: Accounting::TenancyActivityQuery.call(tenancy: tenancy, date_range: date_range)
      )

      expect(pdf).to start_with("%PDF-")
    end

    it "renders text Prawn's built-in fonts cannot draw instead of failing the download" do
      property.update!(address: "北京路 5 号")
      charge_rent

      pdf = described_class.call(tenancy: tenancy, date_range: date_range, statement: statement)

      expect(pdf).to start_with("%PDF-")
    end
  end

  describe "document contents" do
    let(:texts) { [] }
    let(:tables) { [] }
    # A real document, with only the two drawing calls we want to read
    # intercepted: prawn-table adds `table` per instance, so a verifying
    # instance_double of Prawn::Document cannot stand in for one.
    let(:pdf) { Prawn::Document.new }

    before do
      document = pdf
      allow(Prawn::Document).to receive(:new).and_return(document)
      allow(document).to receive(:text) { |*args| texts << args.first }
      allow(document).to receive(:table) { |*args| tables << args.first }
      allow(document).to receive(:render).and_return("pdf-data")
    end

    # The balances table is drawn first, the rows table second.
    def balance_rows
      tables.first || []
    end

    def row_table
      tables.last || []
    end

    def data_rows
      row_table.drop(1)
    end

    it "identifies the tenancy, the period, and both balances" do
      charge_rent(on: Date.new(2025, 12, 1))
      charge_rent(on: Date.new(2026, 1, 1))

      result = described_class.call(tenancy: tenancy, date_range: date_range, statement: statement)

      expect(result).to eq("pdf-data")
      expect(texts).to include("Tenant account statement")
      expect(texts).to include("Alice Walker")
      expect(texts).to include("#{unit.display_name} · 123 Main St")
      expect(texts).to include("Calendar year 2026")
      expect(balance_rows).to include([ "Opening balance before Jan 1, 2026", "$1,500.00 due" ])
      expect(balance_rows).to include([ "Closing balance as of Dec 31, 2026", "$3,000.00 due" ])
    end

    it "lists the rows with their running balance and no unprintable minus sign" do
      charge_rent(on: Date.new(2026, 1, 1))
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 50_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      described_class.call(tenancy: tenancy, date_range: date_range, statement: statement)

      expect(row_table.first).to eq([ "Date", "Activity", "Notes", "Amount", "Balance" ])
      expect(data_rows.map(&:first)).to eq([ "Jan 1, 2026", "Jan 5, 2026" ])
      expect(data_rows.map { |row| row[3] }).to eq([ "$1,500.00", "-$500.00" ])
      expect(data_rows.map(&:last)).to eq([ "$1,500.00 due", "$1,000.00 due" ])
      expect(row_table.flatten.join).not_to include("−")
    end

    it "keeps a waived charge in the document and labels it as an audit trail" do
      late_fee = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2026, 1, 2)
      ).value!.data[:charge]
      Charges::VoidService.call(charge: late_fee, occurred_on: Date.new(2026, 1, 15))

      described_class.call(tenancy: tenancy, date_range: date_range, statement: statement)

      notes = data_rows.map { |row| row[2] }
      expect(data_rows.size).to eq(2)
      expect(notes.any? { |note| note.include?("Voided") }).to be true
      expect(notes.any? { |note| note.include?("Waiver") }).to be true
      expect(data_rows.map { |row| row[3] }).to eq([ "$50.00", "-$50.00" ])
      expect(texts).to include(Tenancies::StatementExport::AUDIT_NOTE)
    end

    it "says the period is empty rather than drawing an empty table" do
      result = described_class.call(tenancy: tenancy, date_range: date_range, statement: statement)

      expect(result).to eq("pdf-data")
      expect(balance_rows).to include([ "Opening balance before Jan 1, 2026", "Settled" ])
      expect(texts).to include("No account activity in this period.")
      expect(tables.size).to eq(1)
    end

    it "says the all-activity period is empty when nothing happened" do
      described_class.call(tenancy: tenancy, date_range: date_range, activity_rows: [])

      expect(texts).to include("Tenancy financial activity")
      expect(texts).to include("No financial activity in this period.")
      expect(tables).to be_empty
    end

    it "names the participant and the audit state in the all-activity log" do
      charge_rent(on: Date.new(2026, 1, 1))
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 50_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      described_class.call(
        tenancy: tenancy,
        date_range: date_range,
        activity_rows: Accounting::TenancyActivityQuery.call(tenancy: tenancy, date_range: date_range)
      )

      expect(row_table.first).to eq([ "Date", "Event", "Participant", "Notes", "Amount" ])
      expect(data_rows.map { |row| row[2] }).to include("Alice Walker")
    end

    it "describes an open-ended period by its through date" do
      described_class.call(
        tenancy: tenancy,
        date_range: Accounting::DateRange.new(from: nil, through: Date.new(2026, 3, 31)),
        statement: statement(Accounting::DateRange.new(from: nil, through: Date.new(2026, 3, 31)))
      )

      expect(texts).to include("Through Mar 31, 2026")
      expect(balance_rows).to include([ "Opening balance before the first entry", "Settled" ])
    end

    it "describes a custom period by both of its dates" do
      range = Accounting::DateRange.new(from: Date.new(2026, 2, 1), through: Date.new(2026, 3, 31))

      described_class.call(tenancy: tenancy, date_range: range, statement: statement(range))

      expect(texts).to include("Feb 1, 2026 through Mar 31, 2026")
    end
  end
end
