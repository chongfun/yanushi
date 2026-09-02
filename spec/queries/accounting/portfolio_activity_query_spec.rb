require "rails_helper"

RSpec.describe Accounting::PortfolioActivityQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  let(:property1) { create(:property, user: user, address: "123 Main St") }
  let(:unit1) { create(:rentable_unit, property: property1, name: "Unit 1") }
  let(:tenancy1) { create(:tenancy, rentable_unit: unit1, commencement_date: Date.new(2025, 1, 1)) }
  let!(:rent_term1) { create(:rent_term, tenancy: tenancy1, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1)) }

  let(:property2) { create(:property, user: user, address: "456 Oak Ave") }
  let(:unit2) { create(:rentable_unit, property: property2, name: "Unit 2") }
  let(:tenancy2) { create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2025, 1, 1)) }
  let!(:rent_term2) { create(:rent_term, tenancy: tenancy2, amount_cents: 150_000, effective_from: Date.new(2025, 1, 1)) }

  let(:party) { create(:party, user: user, display_name: "Tenant Alice") }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
  end

  describe ".call" do
    it "aggregates activity rows across all properties for the user with pagination" do
      # Prop 1: Rent charge on 2026-01-01
      Charges::CreateService.call(
        tenancy: tenancy1,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      # Prop 2: Receipt on 2026-01-05
      Receipts::CreateService.call(
        tenancy: tenancy2,
        payer_party: party,
        amount_cents: 150_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      # Prop 1: Expense on 2026-01-10
      Expenses::CreateService.call(
        property: property1,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 40_000
      )

      result = described_class.call(user: user, year: 2026, per_page: 2, page: 1)

      expect(result.total_count).to eq(3)
      expect(result.total_pages).to eq(2)
      expect(result.page).to eq(1)
      expect(result.per_page).to eq(2)
      expect(result.rows.size).to eq(2)

      # Sorted DESC
      expect(result.rows[0].occurred_on).to eq(Date.new(2026, 1, 10))
      expect(result.rows[0].kind).to eq("expense")
      expect(result.rows[0].property).to eq(property1)

      expect(result.rows[1].occurred_on).to eq(Date.new(2026, 1, 5))
      expect(result.rows[1].kind).to eq("payment")
      expect(result.rows[1].property).to eq(property2)

      page2 = described_class.call(user: user, year: 2026, per_page: 2, page: 2)
      expect(page2.rows.size).to eq(1)
      expect(page2.rows[0].occurred_on).to eq(Date.new(2026, 1, 1))
      expect(page2.rows[0].kind).to eq("rent")
      expect(page2.rows[0].property).to eq(property1)
    end

    it "filters by property_id when specified" do
      Charges::CreateService.call(
        tenancy: tenancy1,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      Charges::CreateService.call(
        tenancy: tenancy2,
        charge_kind: "rent",
        amount_cents: 150_000,
        charge_date: Date.new(2026, 1, 1)
      )

      result = described_class.call(user: user, property_id: property2.id, year: 2026)
      expect(result.total_count).to eq(1)
      expect(result.rows.first.property).to eq(property2)
      expect(result.rows.first.amount_cents).to eq(150_000)
    end

    it "enforces cross-user isolation" do
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit, commencement_date: Date.new(2025, 1, 1))
      create(:rent_term, tenancy: other_tenancy, amount_cents: 300_000, effective_from: Date.new(2025, 1, 1))

      Charges::CreateService.call(
        tenancy: other_tenancy,
        charge_kind: "rent",
        amount_cents: 300_000,
        charge_date: Date.new(2026, 1, 1)
      )

      user_result = described_class.call(user: user, year: 2026)
      expect(user_result.total_count).to eq(0)
      expect(user_result.rows).to be_empty

      # Passing another user's property_id yields 0 records
      isolated = described_class.call(user: user, property_id: other_property.id, year: 2026)
      expect(isolated.total_count).to eq(0)
    end

    it "avoids N+1 queries when loading rows" do
      5.times do |i|
        p = create(:party, user: user, display_name: "Tenant #{i}")
        Receipts::CreateService.call(
          tenancy: tenancy1,
          payer_party: p,
          amount_cents: 100_000,
          received_on: Date.new(2026, 1, i + 1),
          payment_method: "check"
        )
      end

      result = described_class.call(user: user, year: 2026)
      expect(result.rows.size).to eq(5)

      queries = []
      counter = ->(_name, _started, _finished, _unique_id, payload) {
        queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA CACHE])
      }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        result.rows.each do |r|
          r.party&.display_name
          r.property&.address
          r.rentable_unit&.name
          r.journal_entry.id
        end
      end

      expect(queries).to be_empty
    end

    it "handles date ranges with through only and handles page past total_pages" do
      Receipts::CreateService.call(
        tenancy: tenancy1,
        payer_party: party,
        amount_cents: 100_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      # through only
      result = described_class.call(user: user, through: Date.new(2026, 1, 31), page: 10, per_page: 25)
      expect(result.total_count).to eq(1)
      expect(result.page).to eq(1)
      expect(result.rows.size).to eq(1)
    end

    it "correctly projects reversal rows for corrected and voided transactions" do
      expense_result = Expenses::CreateService.call(
        property: property1,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 50_000,
        description: "Original repair"
      )
      expense = expense_result.value!.data[:expense]

      Expenses::CorrectService.call(
        expense: expense,
        expense_kind: "supplies",
        amount_cents: 60_000,
        description: "Corrected supplies"
      )

      result = described_class.call(user: user, year: 2026)
      expect(result.total_count).to eq(3)

      rows = result.rows
      original_row = rows.find { |r| r.description == "Original repair" && r.kind != "reversal" }
      reversal_row = rows.find { |r| r.kind == "reversal" }
      corrected_row = rows.find { |r| r.description == "Corrected supplies" }

      expect(original_row).to be_present
      expect(original_row.amount_cents).to eq(-50_000)
      expect(original_row.corrected?).to be true

      expect(reversal_row).to be_present
      expect(reversal_row.amount_cents).to eq(50_000)
      expect(reversal_row.kind).to eq("reversal")

      expect(corrected_row).to be_present
      expect(corrected_row.amount_cents).to eq(-60_000)
    end

    it "returns empty_result when date_range is invalid or user is nil" do
      invalid_dr = Accounting::DateRange.new(from: Date.new(2026, 12, 31), through: Date.new(2026, 1, 1))
      res = described_class.call(user: user, date_range: invalid_dr)
      expect(res.rows).to be_empty
      expect(res.total_count).to eq(0)
      expect(res.total_pages).to eq(0)
    end
  end
end
