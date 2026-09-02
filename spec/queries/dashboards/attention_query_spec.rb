require "rails_helper"

RSpec.describe Dashboards::AttentionQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property, name: "Unit 2") }
  let(:tenancy) do
    create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
  end
  let!(:rent_term) do
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end
  let(:party) { create(:party, user: user, display_name: "Jane Smith") }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
    create(:tenancy_party, tenancy: tenancy, party: party)
  end

  describe ".call" do
    it "returns empty array when nothing needs attention" do
      expect(described_class.call(user: user)).to eq([])
    end

    it "returns an inbox_review item when reviewable imported transactions exist" do
      source_doc = create(:source_document, user: user, status: "success")
      create(
        :imported_transaction,
        user: user,
        source_document: source_doc,
        status: "unmatched",
        amount_cents: 240_000,
        payer_name: "Homer Simpson",
        occurred_on: Date.new(2026, 8, 21)
      )

      items = described_class.call(user: user)
      expect(items.size).to eq(1)

      item = items.first
      expect(item.kind).to eq(:inbox_review)
      expect(item.title).to eq("1 imported transaction needs review")
      expect(item.description).to include("$2,400.00", "from Homer Simpson", "Aug 21")
      expect(item.path).to eq("/inbox")
      expect(item.severity).to eq(:warn)
    end

    it "returns import_failed items for failed source documents" do
      create(
        :source_document,
        user: user,
        status: "failed",
        attachment_filename: "chase_statement_aug.pdf",
        error_message: "Multi-page statement PDFs are not supported"
      )

      items = described_class.call(user: user)
      expect(items.size).to eq(1)

      item = items.first
      expect(item.kind).to eq(:import_failed)
      expect(item.title).to eq("A statement upload failed to process")
      expect(item.description).to eq("chase_statement_aug.pdf · Multi-page statement PDFs are not supported")
      expect(item.path).to eq("/inbox?view=processing")
      expect(item.severity).to eq(:danger)
    end

    it "returns balance_due items for active tenancies with positive balance" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 35_000,
        charge_date: Date.new(2026, 1, 1)
      )

      items = described_class.call(user: user)
      expect(items.size).to eq(1)

      item = items.first
      expect(item.kind).to eq(:balance_due)
      expect(item.title).to eq("Jane Smith owes $350.00")
      expect(item.description).to include(property.address, "Unit 2", "balance outstanding")
      expect(item.path).to eq("/tenancies/#{tenancy.id}")
      expect(item.severity).to eq(:warn)
    end

    it "isolates items strictly to the requested user" do
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit, commencement_date: Date.new(2025, 1, 1))
      create(:rent_term, tenancy: other_tenancy, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1))
      Charges::CreateService.call(
        tenancy: other_tenancy,
        charge_kind: "rent",
        amount_cents: 100_000,
        charge_date: Date.new(2026, 1, 1)
      )

      other_doc = create(
        :source_document,
        user: other_user,
        status: "failed",
        attachment_filename: "other_statement.pdf"
      )
      create(:imported_transaction, user: other_user, source_document: other_doc, status: "unmatched")

      expect(described_class.call(user: user)).to eq([])
      expect(described_class.call(user: other_user).size).to eq(3)
    end

    it "handles nil user, plural transactions, username payer, and empty failed doc message" do
      expect(described_class.call(user: nil)).to eq([])

      source_doc = create(:source_document, user: user, status: "success")
      create(:imported_transaction, user: user, source_document: source_doc, status: "unmatched", payer_name: nil, payer_username: "@homers", amount_cents: 100_000)
      create(:imported_transaction, user: user, source_document: source_doc, status: "unmatched", payer_name: nil, payer_username: nil, amount_cents: 50_000)

      doc_failed = create(:source_document, user: user, status: "failed", attachment_filename: "statement.pdf", error_message: "")

      items = described_class.call(user: user)
      inbox_item = items.find { |i| i.kind == :inbox_review }
      expect(inbox_item.title).to eq("2 imported transactions need review")

      failed_item = items.find { |i| i.kind == :import_failed }
      expect(failed_item.description).to eq("statement.pdf · Processing failed")
    end

    it "handles imported transaction with nil amount_cents" do
      source_doc = create(:source_document, user: user, status: "success")
      create(:imported_transaction, user: user, source_document: source_doc, status: "unmatched", amount_cents: nil, occurred_on: Date.new(2026, 8, 21), payer_name: "John Doe")

      items = described_class.call(user: user)
      inbox_item = items.find { |i| i.kind == :inbox_review }
      expect(inbox_item.description).to eq("from John Doe, Aug 21")
    end

    it "surfaces positive balance from a terminated/past tenancy" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 80_000,
        charge_date: Date.current - 5.days
      )
      tenancy.update!(termination_date: Date.current - 1.day)

      items = described_class.call(user: user)
      balance_item = items.find { |i| i.kind == :balance_due }
      expect(balance_item).not_to be_nil
      expect(balance_item.title).to eq("Jane Smith owes $800.00")
      expect(balance_item.description).to include("Past tenancy · balance outstanding")
    end

    it "handles tenancies without assigned parties" do
      unit_x = create(:rentable_unit, property: property, name: "Unit X")
      orphan_tenancy = create(:tenancy, rentable_unit: unit_x, agreement_type: "month_to_month", commencement_date: Date.current)
      Charges::CreateService.call(
        tenancy: orphan_tenancy,
        charge_kind: "late_fee",
        amount_cents: 25_000,
        charge_date: Date.current
      )

      items = described_class.call(user: user)
      orphan_item = items.find { |i| i.path.include?(orphan_tenancy.id.to_s) }
      expect(orphan_item).not_to be_nil
      expect(orphan_item.title).to eq("Tenant owes $250.00")
    end

    it "surfaces positive balance from an upcoming tenancy with Upcoming tenancy description" do
      unit_up = create(:rentable_unit, property: property, name: "Unit Upcoming")
      upcoming_tenancy = create(:tenancy, :month_to_month, rentable_unit: unit_up, commencement_date: Date.current + 1.month)
      future_tenant = create(:party, user: user, display_name: "Future Tenant")
      create(:tenancy_party, tenancy: upcoming_tenancy, party: future_tenant)

      Charges::CreateService.call(
        tenancy: upcoming_tenancy,
        charge_kind: "late_fee",
        amount_cents: 25_000,
        charge_date: Date.current
      )

      items = described_class.call(user: user)
      upcoming_item = items.find { |i| i.path.include?(upcoming_tenancy.id.to_s) }
      expect(upcoming_item).not_to be_nil
      expect(upcoming_item.title).to eq("Future Tenant owes $250.00")
      expect(upcoming_item.description).to include("Upcoming tenancy · balance outstanding")
    end

    it "restricts balance due debtor name to active tenants, excluding guarantors and former tenants" do
      unit_turn = create(:rentable_unit, property: property, name: "Unit Turn")
      turn_tenancy = create(:tenancy, rentable_unit: unit_turn, agreement_type: "fixed_term", commencement_date: Date.current - 6.months, termination_date: Date.current + 6.months)
      create(:rent_term, tenancy: turn_tenancy, amount_cents: 100_000, effective_from: Date.current - 6.months)

      alice = create(:party, user: user, display_name: "Alice Past")
      bob = create(:party, user: user, display_name: "Bob Present")
      gary = create(:party, user: user, display_name: "Gary Guarantor")

      # Alice was tenant for first 3 months
      create(:tenancy_party, tenancy: turn_tenancy, party: alice, role: "tenant", effective_from: Date.current - 6.months, effective_until: Date.current - 3.months)
      # Bob is tenant from 3 months ago onward
      create(:tenancy_party, tenancy: turn_tenancy, party: bob, role: "tenant", effective_from: Date.current - 3.months, effective_until: Date.current + 6.months)
      # Gary is guarantor for entire lease
      create(:tenancy_party, tenancy: turn_tenancy, party: gary, role: "guarantor", effective_from: Date.current - 6.months, effective_until: Date.current + 6.months)

      Charges::CreateService.call(
        tenancy: turn_tenancy,
        charge_kind: "rent",
        amount_cents: 50_000,
        charge_date: Date.current
      )

      items = described_class.call(user: user)
      turn_item = items.find { |i| i.path.include?(turn_tenancy.id.to_s) }
      expect(turn_item).not_to be_nil
      expect(turn_item.title).to eq("Bob Present owes $500.00")
      expect(turn_item.title).not_to include("Alice")
      expect(turn_item.title).not_to include("Gary")
    end
  end
end
