require "rails_helper"

RSpec.describe "Properties", type: :request do
  let(:user) { create(:user) }
  let!(:property) { create(:property, user: user) }

  before do
    sign_in_as(user)
  end

  describe "GET /properties" do
    it "renders a successful response" do
      get properties_url
      expect(response).to be_successful
    end
  end

  describe "GET /properties/new" do
    it "renders a successful response" do
      get new_property_url
      expect(response).to be_successful
    end
  end

  describe "POST /properties" do
    it "creates a new Property with implicit main unit (HTML & JSON)" do
      expect {
        post properties_url, params: { property: { address: "789 Pine Rd", asset_type: "single_family", square_footage: 1800 } }
      }.to change(Property, :count).by(1).and change(RentableUnit, :count).by(1)

      expect(response).to redirect_to(property_url(Property.last))

      post properties_url(format: :json), params: { property: { address: "790 Pine Rd", asset_type: "commercial", square_footage: 2000 } }
      expect(response).to have_http_status(:created)
    end

    it "renders new on validation failure (HTML & JSON)" do
      expect {
        post properties_url, params: { property: { address: "" } }
      }.not_to change(Property, :count)

      expect(response).to have_http_status(:unprocessable_content)

      post properties_url(format: :json), params: { property: { address: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /properties/:id" do
    it "renders a successful response" do
      get property_url(property)
      expect(response).to be_successful
    end

    it "displays property security deposits held balance" do
      Accounting::ChartOfAccounts.ensure_for(user)
      unit = create(:rentable_unit, property: property)
      tenancy = create(:tenancy, rentable_unit: unit)
      party = create(:party, user: user)
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 150_000,
        occurred_on: Date.current
      )

      get property_url(property)
      expect(response).to be_successful
      expect(response.body).to include("Security Deposits Held")
      expect(response.body).to include("$1,500.00")
      expect(response.body).to include("Current refundable liability")

      # Viewing past year (2025) still shows current liability in quick-stat, while 2025 ledger has $0
      get property_url(property, year: 2025)
      expect(response).to be_successful
      expect(response.body).to include("Current refundable liability")
      expect(response.body).to include("$1,500.00")
    end

    it "handles invalid date range by showing flash alert and suppressing summary cards" do
      Accounting::ChartOfAccounts.ensure_for(user)
      unit = create(:rentable_unit, property: property)
      tenancy = create(:tenancy, rentable_unit: unit)
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current
      )

      get property_url(property, from: "2026-12-31", through: "2026-01-01")
      expect(response).to be_successful
      expect(response.body).to include("From date cannot be after through date")
      expect(response.body).to include("Unable to calculate financial summary")
      # Summary cards and balance claims are suppressed
      expect(response.body).not_to include("Cash Movement (Period)")
      expect(response.body).not_to include("Operating Activity (Accrual)")
      expect(response.body).not_to include("Tenant Receivable:")
    end

    it "links Schedule E and formats empty state accurately for single-year and multi-year custom ranges" do
      Accounting::ChartOfAccounts.ensure_for(user)

      # 1. Custom range within single calendar year 2025
      get property_url(property, from: "2025-03-01", through: "2025-03-31")
      expect(response).to be_successful
      expect(response.body).to include("schedule_e?year=2025")
      expect(response.body).to include("No financial activity found for the selected period.")

      # 2. Custom multi-year range 2024-2025: Schedule E is disabled with tooltip
      get property_url(property, from: "2024-11-01", through: "2025-03-31")
      expect(response).to be_successful
      expect(response.body).not_to include("schedule_e_property_path")
      expect(response.body).to include("Choose a single tax year to view Schedule E")
      expect(response.body).to include("No financial activity found for the selected period.")
    end
  end

  describe "GET /properties/:id/edit" do
    it "renders a successful response" do
      get edit_property_url(property)
      expect(response).to be_successful
    end
  end

  describe "PATCH /properties/:id" do
    it "updates the property and redirects (HTML & JSON)" do
      patch property_url(property), params: { property: { address: "Updated Address" } }
      expect(response).to redirect_to(property_url(property))
      expect(property.reload.address).to eq("Updated Address")

      patch property_url(property, format: :json), params: { property: { address: "JSON Updated Address" } }
      expect(response).to have_http_status(:ok)
    end

    it "renders edit on validation failure (HTML & JSON)" do
      patch property_url(property), params: { property: { address: "" } }
      expect(response).to have_http_status(:unprocessable_content)

      patch property_url(property, format: :json), params: { property: { address: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /properties/:id" do
    it "destroys an unused property and redirects (HTML & JSON)" do
      expect {
        delete property_url(property)
      }.to change(Property, :count).by(-1)

      expect(response).to redirect_to(properties_url)

      second_property = create(:property, user: user)
      delete property_url(second_property, format: :json)
      expect(response).to have_http_status(:no_content)
    end

    it "prevents deleting a property with expense history (HTML & JSON)" do
      create(:expense, :posted, property: property, amount_cents: 25_000, paid_on: Date.current)

      expect {
        delete property_url(property)
      }.not_to change(Property, :count)

      expect(response).to redirect_to(property_url(property))
      follow_redirect!
      expect(response.body).to include("Cannot delete record because dependent expenses exist")

      delete property_url(property, format: :json)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /properties/:id/schedule_e_pdf" do
    it "downloads schedule_e_pdf for available year" do
      get schedule_e_pdf_property_url(property, year: 2025)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to match(/attachment/)
    end

    it "redirects and shows alert for missing schedule_e_pdf" do
      get schedule_e_pdf_property_url(property, year: 2026)
      expect(response).to redirect_to(property_path(property, year: 2026))
      expect(flash[:alert]).to eq("No Schedule E PDF template found for year 2026")
    end

    it "defaults to current year if year parameter is not specified" do
      allow_any_instance_of(ScheduleEGenerator).to receive(:template_path).and_return(Rails.root.join("app/assets/pdfs/f1040se--2025.pdf"))
      get schedule_e_pdf_property_url(property)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
    end
  end

  describe "GET /properties/:id/schedule_e" do
    it "renders the schedule_e worksheet successfully when profile is configured" do
      create(:property_tax_profile, property: property, tax_year: 2026, schedule_e_property_type: "multi_family_residence")
      get schedule_e_property_url(property, year: 2026)
      expect(response).to be_successful
      expect(response.body).to include("Schedule E Worksheet")
      expect(response.body).to include("2 — Multi-Family Residence")
      expect(response.body).to include("Part I — Income")
      expect(response.body).to include("Part I — Expenses")
      expect(response.body).to include("Not tracked or computed by Yanushi")
    end

    it "shows prompt to configure tax profile when not configured for requested year" do
      get schedule_e_property_url(property, year: 2024)
      expect(response).to be_successful
      expect(response.body).to include("Tax Profile Required")
      expect(response.body).to include("Configure tax classification now")
    end

    it "returns 404 for unowned property" do
      other_user = create(:user)
      other_prop = create(:property, user: other_user)
      get schedule_e_property_url(other_prop)
      expect(response).to have_http_status(:not_found)
    end
  end
end
