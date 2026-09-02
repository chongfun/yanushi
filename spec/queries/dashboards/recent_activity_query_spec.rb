require "rails_helper"

RSpec.describe Dashboards::RecentActivityQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  let(:property) { create(:property, user: user, address: "123 Main St") }
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
    it "returns empty array when user has no activity" do
      expect(described_class.call(user: other_user)).to eq([])
    end

    it "returns up to limit newest-first activity rows" do
      10.times do |i|
        Charges::CreateService.call(
          tenancy: tenancy,
          charge_kind: "late_fee",
          amount_cents: (i + 1) * 1_000,
          charge_date: Date.new(2026, 1, i + 1)
        )
      end

      rows = described_class.call(user: user, through: Date.new(2026, 1, 31), limit: 8)

      expect(rows.size).to eq(8)
      expect(rows.first.occurred_on).to eq(Date.new(2026, 1, 10))
      expect(rows.last.occurred_on).to eq(Date.new(2026, 1, 3))
      expect(rows).to all(be_a(Accounting::ActivityRow))
    end

    it "excludes future-dated journal entries beyond through" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 8, 1)
      )
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 9, 1)
      )

      rows = described_class.call(user: user, through: Date.new(2026, 8, 24))

      expect(rows.size).to eq(1)
      expect(rows.first.occurred_on).to eq(Date.new(2026, 8, 1))
    end

    it "preserves previous-year events across January 1" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2025, 12, 31)
      )

      rows = described_class.call(user: user, through: Date.new(2026, 1, 1), limit: 5)

      expect(rows.size).to eq(1)
      expect(rows.first.occurred_on).to eq(Date.new(2025, 12, 31))
    end

    it "evaluates as_of correctly so an entry with a future reversal remains active" do
      charge_result = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 8, 20)
      )
      original_entry = charge_result.value!.data[:journal_entry]

      # Reversal on Sep 1
      Accounting::ReverseEntryService.call(
        journal_entry: original_entry,
        occurred_on: Date.new(2026, 9, 1),
        description: "Reversal of August rent"
      )

      # As of Aug 24: reversal row (Sep 1) is excluded, original charge (Aug 20) is still :active
      rows_aug = described_class.call(user: user, through: Date.new(2026, 8, 24))
      expect(rows_aug.size).to eq(1)
      expect(rows_aug.first.active?).to be true
      expect(rows_aug.first.lifecycle_status).to eq(:active)
      expect(rows_aug.first.occurred_on).to eq(Date.new(2026, 8, 20))

      # As of Sep 2: reversal row is present, original charge is :corrected
      rows_sep = described_class.call(user: user, through: Date.new(2026, 9, 2))
      expect(rows_sep.size).to eq(2)
      original_row = rows_sep.find { |r| r.occurred_on == Date.new(2026, 8, 20) }
      expect(original_row.corrected?).to be true
      expect(original_row.lifecycle_status).to eq(:corrected)
    end

    it "eager-loads associations to avoid N+1 queries when projecting entries" do
      10.times do |i|
        Charges::CreateService.call(
          tenancy: tenancy,
          charge_kind: "late_fee",
          amount_cents: (i + 1) * 1_000,
          charge_date: Date.new(2026, 1, i + 1)
        )
      end

      # Warm schema/models
      described_class.call(user: user, through: Date.new(2026, 1, 31), limit: 1)

      queries_for_3 = []
      callback3 = lambda do |_name, _start, _finish, _id, payload|
        queries_for_3 << payload[:sql] unless payload[:sql].include?("SCHEMA")
      end
      ActiveSupport::Notifications.subscribed(callback3, "sql.active_record") do
        rows = described_class.call(user: user, through: Date.new(2026, 1, 31), limit: 3)
        rows.each do |row|
          row.label
          row.property&.address
          row.rentable_unit&.name
          row.active?
          row.amount_cents
        end
      end

      queries_for_8 = []
      callback8 = lambda do |_name, _start, _finish, _id, payload|
        queries_for_8 << payload[:sql] unless payload[:sql].include?("SCHEMA")
      end
      ActiveSupport::Notifications.subscribed(callback8, "sql.active_record") do
        rows = described_class.call(user: user, through: Date.new(2026, 1, 31), limit: 8)
        rows.each do |row|
          row.label
          row.property&.address
          row.rentable_unit&.name
          row.active?
          row.amount_cents
        end
      end

      # Query count must remain constant regardless of result row count (no per-row N+1)
      expect(queries_for_8.size).to eq(queries_for_3.size)
    end

    it "isolates recent activity strictly to the requested user" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current
      )

      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit, commencement_date: Date.new(2025, 1, 1))
      create(:rent_term, tenancy: other_tenancy, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1))
      Charges::CreateService.call(
        tenancy: other_tenancy,
        charge_kind: "rent",
        amount_cents: 100_000,
        charge_date: Date.current
      )

      user_rows = described_class.call(user: user)
      other_rows = described_class.call(user: other_user)

      expect(user_rows.size).to eq(1)
      expect(user_rows.first.amount_cents).to eq(200_000)

      expect(other_rows.size).to eq(1)
      expect(other_rows.first.amount_cents).to eq(100_000)
    end

    it "handles nil user, blank through, string through, time through, and invalid date formats" do
      expect(described_class.call(user: nil)).to eq([])

      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current
      )

      expect(described_class.call(user: user, through: "").size).to eq(1)
      expect(described_class.call(user: user, through: Date.current.to_s).size).to eq(1)
      expect(described_class.call(user: user, through: Time.current).size).to eq(1)
      expect(described_class.call(user: user, through: DateTime.current).size).to eq(1)
      expect(described_class.call(user: user, through: "invalid-date").size).to eq(1)
    end
  end
end
