require "rails_helper"

RSpec.describe Dashboards::AttentionQuery do
  include ActiveSupport::Testing::TimeHelpers

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

  # Both the overdue rule and the Schedule E filing year key off today, so pin
  # the clock; the block form guarantees it is restored for later examples.
  around do |example|
    travel_to(Date.new(2026, 9, 15)) { example.run }
  end

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

    it "returns a balance_due item once a charge is past the tenancy's grace period" do
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
      expect(item.title).to eq("Jane Smith is $350.00 overdue")
      expect(item.description).to eq("#{property.address} · Unit 2")
      expect(item.path).to eq("/tenancies/#{tenancy.id}")
      expect(item.severity).to eq(:warn)
    end

    it "stays silent while the whole balance is inside the tenancy's grace period" do
      expect(tenancy.late_period_days).to eq(5)
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current
      )

      expect(tenancy.current_balance_cents).to eq(200_000)
      expect(described_class.call(user: user)).to eq([])
    end

    it "stays silent on the last day of the grace period" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.current - 5.days
      )

      expect(described_class.call(user: user)).to eq([])
    end

    it "names only the overdue part and says how much of the balance is not yet due" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 7_500,
        charge_date: Date.current - 30.days
      )
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current
      )

      items = described_class.call(user: user)
      expect(items.size).to eq(1)
      expect(items.first.title).to eq("Jane Smith is $75.00 overdue")
      expect(items.first.description).to eq("#{property.address} · Unit 2 · $2,000.00 more not yet due")
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

    it "handles imported transaction with nil amount_cents and nil occurred_on" do
      source_doc = create(:source_document, user: user, status: "success")
      create(:imported_transaction, user: user, source_document: source_doc, status: "unmatched", amount_cents: nil, occurred_on: Date.new(2026, 8, 21), payer_name: "John Doe")

      items = described_class.call(user: user)
      inbox_item = items.find { |i| i.kind == :inbox_review }
      expect(inbox_item.description).to eq("from John Doe, Aug 21")

      create(:imported_transaction, user: user, source_document: source_doc, status: "unmatched", amount_cents: nil, occurred_on: nil, payer_name: nil, payer_username: nil)
      items_empty = described_class.call(user: user)
      inbox_empty = items_empty.find { |i| i.kind == :inbox_review }
      expect(inbox_empty).not_to be_nil
    end

    it "handles past tenancy with termination_date" do
      unit_p = create(:rentable_unit, property: property, name: "Unit Past")
      past_t = create(:tenancy, rentable_unit: unit_p, agreement_type: "fixed_term", commencement_date: Date.current - 1.year, termination_date: Date.current - 1.month)
      items = described_class.call(user: user, tenancies: [ past_t ], balances: { past_t.id => 10_000 })
      expect(items.first.description).to include("Past tenancy")
    end

    it "handles upcoming tenancy with commencement_date" do
      unit_u = create(:rentable_unit, property: property, name: "Unit Up")
      up_t = create(:tenancy, rentable_unit: unit_u, agreement_type: "fixed_term", commencement_date: Date.current + 1.month)
      items = described_class.call(user: user, tenancies: [ up_t ], balances: { up_t.id => 10_000 })
      expect(items.first.description).to include("Upcoming tenancy")
    end

    it "surfaces overdue money from a terminated/past tenancy" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 80_000,
        charge_date: Date.current - 10.days
      )
      tenancy.update!(termination_date: Date.current - 1.day)

      items = described_class.call(user: user)
      balance_item = items.find { |i| i.kind == :balance_due }
      expect(balance_item).not_to be_nil
      expect(balance_item.title).to eq("Jane Smith is $800.00 overdue")
      expect(balance_item.description).to include("Past tenancy")
    end

    it "handles tenancies without assigned parties" do
      unit_x = create(:rentable_unit, property: property, name: "Unit X")
      orphan_tenancy = create(:tenancy, rentable_unit: unit_x, agreement_type: "month_to_month", commencement_date: Date.current - 1.month)
      Charges::CreateService.call(
        tenancy: orphan_tenancy,
        charge_kind: "late_fee",
        amount_cents: 25_000,
        charge_date: Date.current - 10.days
      )

      items = described_class.call(user: user)
      orphan_item = items.find { |i| i.path.include?(orphan_tenancy.id.to_s) }
      expect(orphan_item).not_to be_nil
      expect(orphan_item.title).to eq("Tenant is $250.00 overdue")
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
        charge_date: Date.current - 10.days
      )

      items = described_class.call(user: user)
      upcoming_item = items.find { |i| i.path.include?(upcoming_tenancy.id.to_s) }
      expect(upcoming_item).not_to be_nil
      expect(upcoming_item.title).to eq("Future Tenant is $250.00 overdue")
      expect(upcoming_item.description).to include("Upcoming tenancy")
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
        charge_date: Date.current - 10.days
      )

      items = described_class.call(user: user)
      turn_item = items.find { |i| i.path.include?(turn_tenancy.id.to_s) }
      expect(turn_item).not_to be_nil
      expect(turn_item.title).to eq("Bob Present is $500.00 overdue")
      expect(turn_item.title).not_to include("Alice")
      expect(turn_item.title).not_to include("Gary")
    end
  end

  describe "unresolved Schedule E work" do
    let(:filing_year) { Date.current.year - 1 }

    # Ledger activity in `year` for `target`, plus a clean rent receipt so the
    # property is Schedule E "ready" once it has a tax profile.
    def seed_activity(target, year: filing_year)
      target_unit = create(:rentable_unit, property: target, name: "Filing unit #{target.id}")
      target_tenancy = create(
        :tenancy,
        rentable_unit: target_unit,
        commencement_date: Date.new(year, 1, 1),
        termination_date: Date.new(year, 12, 31)
      )
      create(:rent_term, tenancy: target_tenancy, amount_cents: 100_000, effective_from: Date.new(year, 1, 1))
      Receipts::CreateService.call(
        tenancy: target_tenancy,
        payer_party: create(:party, user: user),
        amount_cents: 100_000,
        received_on: Date.new(year, 6, 1),
        payment_method: "check"
      )
    end

    def add_tax_profile(target, year: filing_year)
      create(
        :property_tax_profile,
        property: target,
        tax_year: year,
        schedule_e_property_type: "single_family_residence"
      )
    end

    it "raises no item when no year before this one has ledger activity" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 25_000,
        charge_date: Date.current - 10.days
      )

      expect(described_class.call(user: user).map(&:kind)).to eq([ :balance_due ])
    end

    it "raises no item when every property is ready for the filing year" do
      seed_activity(property)
      add_tax_profile(property)

      expect(described_class.call(user: user)).to eq([])
    end

    it "raises an item when a property has no tax profile for the filing year" do
      seed_activity(property)

      items = described_class.call(user: user)
      expect(items.map(&:kind)).to eq([ :schedule_e_review ])

      item = items.first
      expect(item.title).to eq("1 property is not ready for Schedule E")
      expect(item.description).to eq("#{filing_year} tax year · 1 property needs a tax profile")
      expect(item.path).to eq("/reports?year=#{filing_year}")
      expect(item.severity).to eq(:warn)
    end

    it "raises an item when a property has unresolved review items" do
      add_tax_profile(property)
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(filing_year, 9, 12),
        event_type: "deposit_applied",
        source: property
      )
      create(:posting, journal_entry: entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      items = described_class.call(user: user)
      expect(items.map(&:kind)).to eq([ :schedule_e_review ])
      expect(items.first.title).to eq("1 property is not ready for Schedule E")
      expect(items.first.description).to eq("#{filing_year} tax year · 1 item needs review")
    end

    it "aggregates every unready property into one item" do
      seed_activity(property)
      seed_activity(create(:property, user: user, address: "9 Elm St"))

      items = described_class.call(user: user).select { |i| i.kind == :schedule_e_review }
      expect(items.size).to eq(1)
      expect(items.first.title).to eq("2 properties are not ready for Schedule E")
      expect(items.first.description).to eq("#{filing_year} tax year · 2 properties need a tax profile")
    end

    it "files against the most recent completed year that has ledger activity" do
      seed_activity(property, year: filing_year - 2)

      item = described_class.call(user: user).find { |i| i.kind == :schedule_e_review }
      expect(item).not_to be_nil
      expect(item.path).to eq("/reports?year=#{filing_year - 2}")
      expect(item.description).to start_with("#{filing_year - 2} tax year")
    end

    it "ignores another user's unready properties" do
      seed_activity(property)
      add_tax_profile(property)
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(
        :tenancy,
        rentable_unit: other_unit,
        commencement_date: Date.new(filing_year, 1, 1),
        termination_date: Date.new(filing_year, 12, 31)
      )
      create(:rent_term, tenancy: other_tenancy, amount_cents: 100_000, effective_from: Date.new(filing_year, 1, 1))
      Receipts::CreateService.call(
        tenancy: other_tenancy,
        payer_party: create(:party, user: other_user),
        amount_cents: 100_000,
        received_on: Date.new(filing_year, 6, 1),
        payment_method: "check"
      )

      expect(described_class.call(user: user)).to eq([])
      expect(described_class.call(user: other_user).map(&:kind)).to eq([ :schedule_e_review ])
    end

    # The counts cost one full Schedule E computation per property, so the
    # dashboard must not pay that on every load. The cache key names every
    # input that can change the answer, so cheapness cannot cost accuracy.
    describe "cost on the dashboard" do
      def count_schedule_e_queries
        count = 0
        subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
        end
        described_class.call(user: user)
        ActiveSupport::Notifications.unsubscribe(subscription)
        count
      end

      before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

      # A deposit applied to a charge classifies as review_required, whatever
      # the entry hangs off; one entry per source and event type is all the
      # ledger allows, so two of them need two sources.
      def review_entry(day:, source:)
        entry = create(
          :journal_entry,
          user: user,
          occurred_on: Date.new(filing_year, 9, day),
          event_type: "deposit_applied",
          source: source
        )
        create(:posting, journal_entry: entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
        create(:posting, journal_entry: entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "security_deposits_held"))
        entry
      end

      def resolve(entry)
        create(
          :property_tax_review_resolution,
          property: property,
          tax_year: filing_year,
          journal_entry: entry,
          treatment: "exclude"
        )
      end

      it "does not scale with the portfolio once the summary is cached" do
        5.times { seed_activity(create(:property, user: user)) }

        cold = count_schedule_e_queries
        warm = count_schedule_e_queries

        # Five more properties must not make the cached read any dearer.
        5.times { |i| seed_activity(create(:property, user: user)) }
        Rails.cache.clear
        count_schedule_e_queries
        warm_with_ten = count_schedule_e_queries

        expect(warm).to be < cold
        expect(warm_with_ten).to eq(warm)
      end

      it "recomputes when a resolution changes the answer" do
        add_tax_profile(property)
        entry = create(
          :journal_entry,
          user: user,
          occurred_on: Date.new(filing_year, 9, 12),
          event_type: "deposit_applied",
          source: property
        )
        create(:posting, journal_entry: entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
        create(:posting, journal_entry: entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

        expect(described_class.call(user: user).map(&:kind)).to eq([ :schedule_e_review ])

        # Resolving the review item clears the attention item, cache or not.
        create(
          :property_tax_review_resolution,
          property: property,
          tax_year: filing_year,
          journal_entry: entry,
          treatment: "exclude"
        )

        expect(described_class.call(user: user)).to eq([])
      end

      it "recomputes for a resolution recorded in the same second as the one before it" do
        add_tax_profile(property)
        first = review_entry(day: 12, source: property)
        second = review_entry(day: 13, source: tenancy)

        expect(described_class.call(user: user).map(&:kind)).to eq([ :schedule_e_review ])

        # Postgres keeps microseconds, and two resolutions inside one second is
        # an ordinary way to clear a short review list. A key carrying whole
        # seconds cannot tell these two apart, and the dashboard would go on
        # asking for work that is already done until the entry expired.
        # The block form refuses to nest inside the clock this file already
        # pins, and `with_usec` is what keeps the fractional second that the
        # whole point of this example rests on.
        same_second = Time.current

        travel_to(same_second + 0.1.seconds, with_usec: true)
        resolve(first)
        expect(described_class.call(user: user).size).to eq(1)

        travel_to(same_second + 0.9.seconds, with_usec: true)
        resolve(second)
        expect(described_class.call(user: user)).to eq([])
      end
    end
  end
end
