require "rails_helper"

RSpec.describe Tenancies::StatementExport, type: :service do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user, address: "123 Main St") }
  let(:unit) { create(:rentable_unit, property: property, name: "Unit 4B", unit_identifier: nil) }
  let(:tenancy) do
    create(:tenancy, :month_to_month, rentable_unit: unit, commencement_date: Date.new(2025, 1, 1))
  end

  def statement_row(**overrides)
    Accounting::TenantReceivableActivityQuery::StatementRow.new(**{
      id: 1,
      occurred_on: Date.new(2026, 1, 1),
      journal_entry: nil,
      kind: "rent",
      label: "Rent",
      description: "Monthly rent",
      amount_cents: 150_000,
      running_balance_cents: 150_000,
      party: nil,
      source: nil,
      reversal: false,
      corrected: false,
      lifecycle_status: :active
    }.merge(overrides))
  end

  def activity_row(**overrides)
    Accounting::ActivityRow.new(**{
      id: 1,
      journal_entry: nil,
      occurred_on: Date.new(2026, 1, 1),
      kind: "payment",
      label: "Payment",
      description: nil,
      amount_cents: -50_000,
      property: nil,
      rentable_unit: nil,
      tenancy: nil,
      party: nil,
      source: nil,
      reversal: false,
      corrected: false,
      lifecycle_status: :active
    }.merge(overrides))
  end

  describe ".title" do
    it "names the view the document was exported from" do
      expect(described_class.title("all")).to eq("Tenancy financial activity")
      expect(described_class.title("receivable")).to eq("Tenant account statement")
      expect(described_class.title(nil)).to eq("Tenant account statement")
    end
  end

  describe ".tenant_names" do
    it "lists the current tenants" do
      first = create(:party, user: user, display_name: "Alice Walker")
      second = create(:party, user: user, display_name: "Bob Walker")
      [ first, second ].each do |party|
        create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant",
          effective_from: Date.new(2025, 1, 1), effective_until: nil)
      end

      expect(described_class.tenant_names(tenancy.reload)).to eq("Alice Walker and Bob Walker")
    end

    it "falls back to every tenant on the tenancy, then says so when there is none" do
      former = create(:party, user: user, display_name: "Carol Walker")
      create(:tenancy_party, tenancy: tenancy, party: former, role: "tenant",
        effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))

      expect(described_class.tenant_names(tenancy.reload)).to eq("Carol Walker")
      expect(described_class.tenant_names(Tenancy.new)).to eq("No tenant on record")
    end
  end

  describe ".identity_lines" do
    it "names the tenants, the unit, and the property" do
      expect(described_class.identity_lines(tenancy)).to eq([
        [ "Tenants", "No tenant on record" ],
        [ "Unit", "Unit 4B" ],
        [ "Property", "123 Main St" ]
      ])
    end

    it "does not fail on a tenancy whose unit has no property yet" do
      draft = Tenancy.new(rentable_unit: RentableUnit.new(name: "Unit 1"))

      expect(described_class.identity_lines(draft)).to include([ "Property", "—" ])
    end
  end

  describe ".period_label" do
    it "reads as a calendar year, a custom range, or an open start" do
      expect(described_class.period_label(Accounting::DateRange.new(year: 2026)))
        .to eq("Calendar year 2026")
      expect(described_class.period_label(Accounting::DateRange.new(from: Date.new(2026, 2, 1), through: Date.new(2026, 3, 31))))
        .to eq("Feb 1, 2026 through Mar 31, 2026")
      expect(described_class.period_label(Accounting::DateRange.new(from: nil, through: Date.new(2026, 3, 31))))
        .to eq("Through Mar 31, 2026")
    end
  end

  describe "money" do
    it "matches the app's formatting with a printable minus sign" do
      expect(described_class.money(150_000)).to eq("$1,500.00")
      expect(described_class.signed_money(-50_000)).to eq("-$500.00")
      expect(described_class.signed_money(50_000)).to eq("$500.00")
      expect(described_class.balance(150_000)).to eq("$1,500.00 due")
      expect(described_class.balance(-150_000)).to eq("$1,500.00 credit")
      expect(described_class.balance(0)).to eq("Settled")
    end
  end

  describe ".text" do
    it "transliterates what the built-in PDF fonts cannot draw" do
      expect(described_class.text("北京")).to eq("??")
      expect(described_class.text("Café · Ltd")).to eq("Café · Ltd")
      expect(described_class.text(nil)).to eq("")
    end
  end

  describe "row labels" do
    it "prefers the description and falls back to the projected label" do
      expect(described_class.activity_label(statement_row)).to eq("Monthly rent")
      expect(described_class.activity_label(statement_row(description: nil))).to eq("Rent")
    end

    it "appends an all-activity description only when it adds something" do
      expect(described_class.event_label(activity_row)).to eq("Payment")
      expect(described_class.event_label(activity_row(description: "Payment"))).to eq("Payment")
      expect(described_class.event_label(activity_row(description: "Check 1204"))).to eq("Payment · Check 1204")
    end

    it "names the participant, or says there is none" do
      party = create(:party, user: user, display_name: "Alice Walker")

      expect(described_class.party_name(activity_row(party: party))).to eq("Alice Walker")
      expect(described_class.party_name(activity_row)).to eq("—")
    end
  end

  describe "audit labels" do
    it "flattens the page's sub-line, including corrections and waivers" do
      expect(described_class.statement_notes(statement_row)).to eq("Rent")
      expect(described_class.statement_notes(statement_row(label: "Monthly rent"))).to eq("")
      expect(described_class.statement_notes(statement_row(reversal: true, kind: "waiver")))
        .to eq("Rent · Waiver")
      expect(described_class.statement_notes(statement_row(reversal: true, kind: "reversal")))
        .to eq("Rent · Correction")
      expect(described_class.statement_notes(statement_row(lifecycle_status: :corrected)))
        .to eq("Rent · Corrected")
      expect(described_class.statement_notes(statement_row(lifecycle_status: :voided)))
        .to eq("Rent · Voided")
    end

    it "says nothing about a healthy all-activity row and names a broken one" do
      expect(described_class.audit_note(activity_row)).to eq("")
      expect(described_class.audit_note(activity_row(lifecycle_status: :corrected))).to eq("Corrected")
      expect(described_class.audit_note(activity_row(lifecycle_status: :voided))).to eq("Voided")
    end

    it "reduces the lifecycle to one filterable word" do
      expect(described_class.status_word(activity_row)).to eq("Active")
      expect(described_class.status_word(activity_row(lifecycle_status: :corrected))).to eq("Corrected")
      expect(described_class.status_word(activity_row(lifecycle_status: :voided))).to eq("Voided")
    end
  end

  describe "dates" do
    it "reads long in documents and ISO in spreadsheets" do
      expect(described_class.long_date(Date.new(2026, 1, 5))).to eq("Jan 5, 2026")
      expect(described_class.iso_date(Date.new(2026, 1, 5))).to eq("2026-01-05")
    end
  end
end
