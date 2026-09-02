require "rails_helper"

RSpec.describe "Tenancies", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:other_property) { create(:property, user: other_user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:other_unit) { create(:rentable_unit, property: other_property) }
  let(:party) { create(:party, user: user) }
  let!(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      agreement_type: "fixed_term",
      commencement_date: Date.current.beginning_of_month,
      termination_date: Date.current.beginning_of_month + 1.year
    )
  end
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 150_000,
      effective_from: Date.current.beginning_of_month,
      effective_until: Date.current.beginning_of_month + 1.year
    )
  end
  let!(:tenancy_party) do
    create(:tenancy_party,
      tenancy: tenancy,
      party: party,
      role: "tenant",
      effective_from: tenancy.commencement_date,
      effective_until: tenancy.termination_date
    )
  end

  before do
    sign_in_as(user)
  end

  describe "GET /tenancies" do
    it "renders a successful response" do
      get tenancies_url
      expect(response).to be_successful
    end
  end

  describe "GET /tenancies/new" do
    it "filters units and parties to only include the current user's" do
      other_party = create(:party, user: other_user, display_name: "Other Party")

      get new_tenancy_url
      expect(response).to be_successful
      expect(response.body).not_to include(other_property.address)
      expect(response.body).not_to include("Other Party")
    end

    it "preselects the rentable unit when a valid unit belonging to the user is passed" do
      vacant_unit = create(:rentable_unit, property: property, name: "Unit 101")

      get new_tenancy_url(rentable_unit_id: vacant_unit.id)
      expect(response).to be_successful
      expect(response.body).to include("value=\"#{vacant_unit.id}\" selected")
    end

    it "ignores rentable_unit_id belonging to another user" do
      get new_tenancy_url(rentable_unit_id: other_unit.id)
      expect(response).to be_successful
      expect(response.body).not_to include("value=\"#{other_unit.id}\"")
    end
  end

  describe "POST /tenancies" do
    let(:new_unit) { create(:rentable_unit, property: property) }

    it "creates a tenancy with valid attributes (HTML & JSON)" do
      expect {
        post tenancies_url, params: {
          tenancy: {
            rentable_unit_id: new_unit.id,
            agreement_type: "fixed_term",
            commencement_date: Date.current,
            termination_date: Date.current + 1.year,
            late_period_days: 5,
            party_ids: [ party.id ],
            rent_amount: "1850.00"
          }
        }
      }.to change(Tenancy, :count).by(1)
       .and change(TenancyParty, :count).by(1)
       .and change(RentTerm, :count).by(1)

      expect(response).to redirect_to(tenancy_url(Tenancy.last))

      another_unit = create(:rentable_unit, property: property)
      post tenancies_url(format: :json), params: {
        tenancy: {
          rentable_unit_id: another_unit.id,
          agreement_type: "month_to_month",
          commencement_date: Date.current,
          party_ids: [ party.id ],
          rent_amount: "1200.00"
        }
      }
      expect(response).to have_http_status(:created)

      unit4 = create(:rentable_unit, property: property)
      post tenancies_url, params: {
        tenancy: {
          rentable_unit_id: unit4.id,
          agreement_type: "month_to_month",
          commencement_date: Date.current,
          participants: [
            { party_id: party.id, role: "tenant", effective_from: Date.current }
          ],
          initial_rent: {
            amount_cents: 140_000,
            due_day: 1,
            frequency: "monthly",
            effective_from: Date.current
          }
        }
      }
      expect(response).to redirect_to(tenancy_url(Tenancy.last))

      unit5 = create(:rentable_unit, property: property)
      post tenancies_url, params: {
        tenancy: {
          rentable_unit_id: unit5.id,
          agreement_type: "month_to_month",
          commencement_date: Date.current,
          party_ids: [ party.id ],
          rent_amount_cents: 160_000
        }
      }
      expect(response).to redirect_to(tenancy_url(Tenancy.last))
    end

    it "should not create tenancy with other user's unit" do
      expect {
        post tenancies_url, params: {
          tenancy: {
            rentable_unit_id: other_unit.id,
            agreement_type: "fixed_term",
            commencement_date: Date.current,
            termination_date: Date.current + 1.year,
            party_ids: [ party.id ],
            rent_amount: "1500.00"
          }
        }
      }.not_to change(Tenancy, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "should not create tenancy with other user's party" do
      other_party = create(:party, user: other_user)

      expect {
        post tenancies_url, params: {
          tenancy: {
            rentable_unit_id: new_unit.id,
            agreement_type: "fixed_term",
            commencement_date: Date.current,
            termination_date: Date.current + 1.year,
            party_ids: [ other_party.id ],
            rent_amount: "1500.00"
          }
        }
      }.not_to change(Tenancy, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "renders new on validation failure (HTML & JSON)" do
      expect {
        post tenancies_url, params: {
          tenancy: {
            rentable_unit_id: new_unit.id,
            party_ids: [ party.id ],
            agreement_type: "fixed_term",
            commencement_date: Date.current,
            termination_date: nil
          }
        }
      }.not_to change(Tenancy, :count)

      expect(response).to have_http_status(:unprocessable_content)

      post tenancies_url(format: :json), params: {
        tenancy: {
          rentable_unit_id: new_unit.id,
          party_ids: [ party.id ],
          agreement_type: "fixed_term",
          commencement_date: Date.current,
          termination_date: nil
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "handles creating tenancy with empty party_ids" do
      post tenancies_url, params: {
        tenancy: {
          rentable_unit_id: new_unit.id,
          agreement_type: "fixed_term",
          commencement_date: Date.current,
          termination_date: Date.current + 1.year,
          party_ids: [],
          rent_amount: "1500.00"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /tenancies/:id" do
    before do
      Accounting::ChartOfAccounts.ensure_for(user)
    end

    it "renders a successful response" do
      get tenancy_url(tenancy)
      expect(response).to be_successful
    end

    it "excludes future charges from Recent Account Activity and aligns with Current Balance" do
      # 1. Past payment: $1,500 on 5 days ago
      res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 150_000,
        received_on: Date.current - 5.days,
        payment_method: "check"
      )
      expect(res).to be_success

      # 2. Future charge: $1,500 on 10 days in the future
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 150_000,
        charge_date: Date.current + 10.days,
        description: "Future Month Rent"
      )

      get tenancy_url(tenancy)
      expect(response).to be_successful

      # Balance section shows credit from the past payment (excludes future charge)
      expect(response.body).to include("tenancy_balance")
      expect(response.body).to include("credit")

      # Activity section includes past payment, does not include future rent
      expect(response.body).to include("tenancy_activity")
      expect(response.body).to include("Payment")
      expect(response.body).not_to include("Future Month Rent")
    end

    it "distinguishes charge waivers from corrections in Recent Account Activity" do
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.current - 2.days,
        description: "Late Fee"
      )
      charge = charge_res.value!.data[:charge]

      Charges::VoidService.call(charge: charge, occurred_on: Date.current)

      get tenancy_url(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("Waiver")
    end
  end

  describe "GET /tenancies/:id/edit" do
    it "renders a successful response" do
      get edit_tenancy_url(tenancy)
      expect(response).to be_successful
    end
  end

  describe "PATCH /tenancies/:id" do
    it "updates the tenancy and redirects (HTML & JSON)" do
      patch tenancy_url(tenancy), params: { tenancy: { late_period_days: 10 } }
      expect(response).to redirect_to(tenancy_url(tenancy))
      expect(tenancy.reload.late_period_days).to eq(10)

      patch tenancy_url(tenancy, format: :json), params: { tenancy: { late_period_days: 15 } }
      expect(response).to have_http_status(:ok)
    end

    it "renders edit on validation failure (HTML & JSON)" do
      patch tenancy_url(tenancy), params: { tenancy: { termination_date: Date.current - 1.month } }
      expect(response).to have_http_status(:unprocessable_content)

      patch tenancy_url(tenancy, format: :json), params: { tenancy: { termination_date: Date.current - 1.month } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /tenancies/:id" do
    it "destroys a pristine tenancy and redirects (HTML & JSON)" do
      expect {
        delete tenancy_url(tenancy)
      }.to change(Tenancy, :count).by(-1)

      expect(response).to redirect_to(tenancies_url)

      second_unit = create(:rentable_unit, property: property, name: "Second Unit")
      second_tenancy = create(:tenancy, rentable_unit: second_unit)
      delete tenancy_url(second_tenancy, format: :json)
      expect(response).to have_http_status(:no_content)
    end

    it "prevents deleting a tenancy with financial history (HTML & JSON)" do
      create(:receipt, tenancy: tenancy, amount_cents: 150_000, received_on: Date.current)

      expect {
        delete tenancy_url(tenancy)
      }.not_to change(Tenancy, :count)

      expect(response).to redirect_to(tenancy_url(tenancy))
      follow_redirect!
      expect(response.body).to include("Cannot delete record because dependent receipts exist")

      delete tenancy_url(tenancy, format: :json)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /tenancies/:id/statement" do
    before do
      Accounting::ChartOfAccounts.ensure_for(user)
    end

    it "renders the running account statement" do
      res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 150_000,
        charge_date: Date.current
      )
      expect(res).to be_success

      get statement_tenancy_path(tenancy)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Tenant Account Statement")
      expect(response.body).to include("Opening Balance")
      expect(response.body).to include("Closing Balance")
      expect(response.body).to include("Rent")
      expect(response.body).to include("$1,500.00")
      expect(response.body).to include("Custom Range")
    end

    it "filters statement by date range" do
      get statement_tenancy_path(tenancy, from: "2026-01-01", through: "2026-12-31")
      expect(response).to have_http_status(:ok)
    end

    it "handles invalid date range by showing flash alert and suppressing balance cards" do
      get statement_tenancy_path(tenancy, from: "2026-12-31", through: "2026-01-01")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("From date cannot be after through date")
      expect(response.body).to include("Unable to generate financial report")
      expect(response.body).not_to include("Opening Balance")
      expect(response.body).not_to include("Closing Balance")
      expect(response.body).not_to include("Paid in full")
      expect(response.body).not_to include("Settled")
    end

    it "accurately labels credit balances and does not display '(Owed)' on overpayment" do
      party = create(:party, user: user)
      # Rent $1,500
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 150_000,
        charge_date: Date.current
      )
      # Payment $1,600 -> $100 credit
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 160_000,
        received_on: Date.current,
        payment_method: "check"
      )

      get statement_tenancy_path(tenancy)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Closing Balance")
      expect(response.body).to include("Tenant credit")
      expect(response.body).not_to include("Closing Balance (Owed)")
      expect(response.body).not_to include("(Owed)")
    end

    it "renders all tenancy financial activity including security deposit transactions when view=all" do
      party = create(:party, user: user)
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 150_000,
        charge_date: Date.current,
        description: "Monthly Rent"
      )
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 100_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        amount_cents: 100_000,
        occurred_on: Date.current,
        party: party,
        memo: "Holding Deposit"
      )

      # 1. Receivable Statement: includes Rent, excludes Deposit Received
      get statement_tenancy_path(tenancy)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Monthly Rent")
      expect(response.body).not_to include("Holding Deposit")

      # 2. All Financial Activity: includes both Rent and Deposit Received
      get statement_tenancy_path(tenancy, view: "all")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Monthly Rent")
      expect(response.body).to include("Holding Deposit")
      expect(response.body).to include("Deposit Received")
    end
  end
end
