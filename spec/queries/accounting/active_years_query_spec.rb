require "rails_helper"

RSpec.describe Accounting::ActiveYearsQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2024, 1, 1), termination_date: nil) }
  let!(:rent_term) do
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2024, 1, 1), effective_until: nil)
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe ".call and instance methods" do
    it "includes current year by default even with no activity" do
      query = described_class.new(property: property)
      expect(query.call).to include(Date.current.year)
    end

    it "includes years derived from journal_entries.occurred_on" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2024, 5, 1)
      )
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2025, 6, 1)
      )

      query = described_class.new(property: property)
      years = query.call
      expect(years).to include(2024, 2025, Date.current.year)
    end

    it "includes reversal-only years where no domain source was created in that year" do
      # 2024 expense
      exp_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.new(2024, 12, 20),
        amount_cents: 50_000
      )
      exp = exp_res.value!.data[:expense]

      # Voided with reversal in 2025
      entry = exp.journal_entries.find_by!(event_type: "expense_posted")
      Accounting::ReverseEntryService.call(
        journal_entry: entry,
        occurred_on: Date.new(2025, 1, 10)
      )

      query = described_class.new(property: property)
      years = query.call
      expect(years).to include(2024, 2025)
    end

    it "includes additional requested years" do
      non_to_i = Object.new
      def non_to_i.respond_to?(m, *) = m == :to_i ? false : super

      query = described_class.new(property: property)
      years = query.call(additional_years: [ 2020, "2021", nil, "invalid", 0, "0", non_to_i ])
      expect(years).to include(2020, 2021)
    end

    it "handles nil property safely" do
      expect(described_class.call(property: nil)).to eq([ Date.current.year ])
    end
  end
end
