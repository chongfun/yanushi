require "rails_helper"

RSpec.describe "Accounts", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
    post session_path, params: { email: user.email, password: "password" }
  end

  describe "GET /accounts" do
    it "renders the list of user accounts with natural balances as of today, excluding future entries" do
      prop = create(:property, user: user)
      unit = create(:rentable_unit, property: prop)
      tenancy = create(:tenancy, rentable_unit: unit)

      # Future charge on Date.current + 10.days
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current + 10.days
      )

      # Tenancy current balance as of today is 0
      expect(tenancy.current_balance_cents).to eq(0)

      get accounts_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Chart of Accounts")
      expect(response.body).to include("Cash")
      expect(response.body).to include("Tenant Receivable")
      expect(response.body).to include("Security Deposits Held")

      # All accounts should show $0.00 as of today, NOT the future $2,000 charge
      expect(response.body).to include("$0.00")
      expect(response.body).not_to include("$2,000.00")
    end
  end

  describe "GET /accounts/:id" do
    let(:account) { user.accounts.find_by!(key: "cash") }
    let(:other_account) { other_user.accounts.find_by!(key: "cash") }
    let(:prop1) { create(:property, user: user, address: "100 Alpha St") }
    let(:prop2) { create(:property, user: user, address: "200 Beta Ave") }

    it "renders account activity details" do
      get account_path(account)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(account.name)
      expect(response.body).to include("Opening Balance")
      expect(response.body).to include("Closing Balance")
    end

    it "filters by date range" do
      get account_path(account, from: "2026-01-01", through: "2026-12-31")
      expect(response).to have_http_status(:ok)
    end

    it "filters by property and tenancy dimensions" do
      unit1 = create(:rentable_unit, property: prop1)
      tenancy1 = create(:tenancy, rentable_unit: unit1)
      party = create(:party, user: user)

      # Receipt on prop1
      Receipts::CreateService.call(
        tenancy: tenancy1,
        payer_party: party,
        amount_cents: 100_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      # Expense on prop2
      Expenses::CreateService.call(
        property: prop2,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 50_000,
        description: "Repair on Beta Ave"
      )

      # Filter by prop1: shows receipt, hides expense
      get account_path(account, property_id: prop1.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("100 Alpha St")
      expect(response.body).not_to include("Repair on Beta Ave")

      # Filter by tenancy1: shows receipt
      get account_path(account, tenancy_id: tenancy1.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("100 Alpha St")
      expect(response.body).not_to include("Repair on Beta Ave")
    end

    it "notifies user and suppresses balance cards when date range is invalid" do
      get account_path(account, from: "2026-12-31", through: "2026-01-01")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("From date cannot be after through date")
      expect(response.body).to include("Unable to calculate account ledger")
      expect(response.body).not_to include("Opening Balance")
      expect(response.body).not_to include("Closing Balance")
    end

    it "fails closed (404) when filtering by non-existent or other user's property/tenancy" do
      other_prop = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_prop)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)

      # Non-existent property
      get account_path(account, property_id: 999_999)
      expect(response).to have_http_status(:not_found)

      # Other user's property
      get account_path(account, property_id: other_prop.id)
      expect(response).to have_http_status(:not_found)

      # Non-existent tenancy
      get account_path(account, tenancy_id: 999_999)
      expect(response).to have_http_status(:not_found)

      # Other user's tenancy
      get account_path(account, tenancy_id: other_tenancy.id)
      expect(response).to have_http_status(:not_found)

      # Mismatched tenancy and property
      unit1 = create(:rentable_unit, property: prop1)
      tenancy1 = create(:tenancy, rentable_unit: unit1)
      get account_path(account, property_id: prop2.id, tenancy_id: tenancy1.id)
      expect(response).to have_http_status(:not_found)

      # Matched tenancy and property succeeds
      get account_path(account, property_id: prop1.id, tenancy_id: tenancy1.id)
      expect(response).to have_http_status(:ok)
    end

    it "prevents accessing other user's account" do
      get account_path(other_account)
      expect(response).to have_http_status(:not_found)
    end

    it "renders the account ledger with constant query count regardless of row count" do
      unit1 = create(:rentable_unit, property: prop1)
      tenancy1 = create(:tenancy, rentable_unit: unit1, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
      party1 = create(:party, user: user)

      # Create 15 charges and receipts
      15.times do |i|
        Charges::CreateService.call(tenancy: tenancy1, charge_kind: "rent", amount_cents: 100_000, charge_date: Date.new(2026, 1, 1))
        Receipts::CreateService.call(tenancy: tenancy1, payer_party: party1, amount_cents: 100_000, received_on: Date.new(2026, 1, 5), payment_method: "check")
      end

      queries = []
      counter = ->(_name, _started, _finished, _unique_id, payload) {
        queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA CACHE])
      }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get account_path(account, year: 2026)
      end

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Payment received - Check")
      # Query count remains small and bounded (session/auth, account lookup, active years, property dropdown, ledger aggregates + preloads)
      expect(queries.size).to be <= 15
    end
  end
end
