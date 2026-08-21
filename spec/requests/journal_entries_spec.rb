require "rails_helper"

RSpec.describe "JournalEntries", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil) }
  let!(:rent_term) do
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
    post session_path, params: { email: user.email, password: "password" }
  end

  describe "GET /journal_entries/:id" do
    it "renders the balanced journal entry audit page" do
      res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1),
        description: "January 2026 Rent"
      )
      entry = res.value!.data[:journal_entry]

      get journal_entry_path(entry)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Journal Entry ##{entry.id}")
      expect(response.body).to include("Tenant Receivable")
      expect(response.body).to include("Rental Income")
      expect(response.body).to include("$2,000.00")
    end

    it "prevents accessing other user's journal entries" do
      other_property = create(:property, user: other_user)
      other_exp = Expenses::CreateService.call(
        property: other_property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 1),
        amount_cents: 10_000
      ).value!.data[:expense]
      other_entry = other_exp.journal_entries.first

      get journal_entry_path(other_entry)
      expect(response).to have_http_status(:not_found)
    end

    it "supports two-way navigation between original entry and reversal entry" do
      res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2026, 1, 10),
        description: "Late Fee"
      )
      orig_entry = res.value!.data[:journal_entry]
      charge = res.value!.data[:charge]

      void_res = Charges::VoidService.call(charge: charge, occurred_on: Date.new(2026, 1, 15))
      rev_entry = void_res.value!.data[:journal_entry]

      # 1. View original entry: links to reversal entry
      get journal_entry_path(orig_entry)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Reversed by")
      expect(response.body).to include(journal_entry_path(rev_entry))

      # 2. View reversal entry: links to original entry
      get journal_entry_path(rev_entry)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Reversal of")
      expect(response.body).to include(journal_entry_path(orig_entry))
    end
  end
end
