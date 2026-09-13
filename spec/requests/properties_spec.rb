require "rails_helper"

RSpec.describe "Properties", type: :request do
  let(:user) { create(:user) }
  let!(:property) { create(:property, user: user) }

  before do
    sign_in_as(user)
  end

  describe "GET /properties" do
    it "redirects the HTML index to the Portfolio landing" do
      get properties_url
      expect(response).to redirect_to(portfolio_url)
      expect(response).to have_http_status(:moved_permanently)
    end

    it "still serves the JSON index" do
      get properties_url(format: :json)
      expect(response).to be_successful
      expect(response.parsed_body.map { |p| p["address"] }).to include(property.address)
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

    it "displays property security deposits held balance and units" do
      Accounting::ChartOfAccounts.ensure_for(user)
      unit = create(:rentable_unit, property: property, name: "Unit 1")
      tenancy = create(:tenancy, rentable_unit: unit)
      party = create(:party, user: user, display_name: "Jane Smith")
      create(:tenancy_party, tenancy: tenancy, party: party)
      create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.current)
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 150_000,
        occurred_on: Date.current
      )

      # Create charge and activity
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 200_000,
        charge_date: Date.current
      )

      get property_url(property)
      expect(response).to be_successful
      expect(response.body).to include("Deposits held")
      expect(response.body).to include("$1,500.00")
      expect(response.body).to include("Unit 1")
      expect(response.body).to include("Jane Smith")
      expect(response.body).to include("Recent activity")
      expect(response.body).to include("$2,000.00 due")
    end

    it "ignores ledger parameters without error and renders overview" do
      get property_url(property, from: "2026-12-31", through: "2026-01-01", year: 2025)
      expect(response).to be_successful
      expect(response.body).to include("Overview")
      expect(response.body).to include("Deposits held")
      expect(response.body).to include("Recent activity")
    end

    it "renders a dash for unit rent when active tenancy is in a legal gap between rent terms" do
      unit_gap = create(:rentable_unit, property: property, name: "Unit Gap")
      gap_tenancy = create(:tenancy, :month_to_month, rentable_unit: unit_gap, commencement_date: Date.current - 6.months)
      create(:tenancy_party, tenancy: gap_tenancy, party: create(:party, user: user, display_name: "Gap Tenant"))
      create(:rent_term, tenancy: gap_tenancy, amount_cents: 200_000, effective_from: Date.current - 6.months, effective_until: Date.current - 1.month)
      create(:rent_term, tenancy: gap_tenancy, amount_cents: 220_000, effective_from: Date.current + 1.month, effective_until: nil)

      get property_url(property)
      expect(response).to be_successful
      expect(response.body).to include("Gap Tenant")
      expect(response.body).not_to include("$2,200.00/mo")
    end

    it "renders active tenant and excludes former tenants and guarantors from unit occupancy" do
      unit_turn = create(:rentable_unit, property: property, name: "Unit Turn")
      turn_tenancy = create(:tenancy, :fixed_term, rentable_unit: unit_turn, commencement_date: Date.current - 6.months, termination_date: Date.current + 6.months)
      create(:rent_term, tenancy: turn_tenancy, amount_cents: 180_000, effective_from: Date.current - 6.months)

      alice = create(:party, user: user, display_name: "Alice Past")
      bob = create(:party, user: user, display_name: "Bob Present")
      gary = create(:party, user: user, display_name: "Gary Guarantor")

      create(:tenancy_party, tenancy: turn_tenancy, party: alice, role: "tenant", effective_from: Date.current - 6.months, effective_until: Date.current - 3.months)
      create(:tenancy_party, tenancy: turn_tenancy, party: bob, role: "tenant", effective_from: Date.current - 3.months, effective_until: Date.current + 6.months)
      create(:tenancy_party, tenancy: turn_tenancy, party: gary, role: "guarantor", effective_from: Date.current - 6.months, effective_until: Date.current + 6.months)

      get property_url(property)
      expect(response).to be_successful
      expect(response.body).to include("Bob Present")
      expect(response.body).not_to include("Alice Past")
      expect(response.body).not_to include("Gary Guarantor")
    end

    it "renders Vacant badge and Create tenancy link for vacant units" do
      vacant_unit = create(:rentable_unit, property: property, name: "Unit 3")

      get property_url(property)
      expect(response).to be_successful
      expect(response.body).to include("Vacant")
      expect(response.body).to include("href=\"#{new_tenancy_path(rentable_unit_id: vacant_unit.id)}\"")
    end

    it "renders Record expense as primary button on Overview" do
      get property_url(property)
      expect(response).to be_successful
      expect(response.body).to match(/class="yn-btn yn-btn-primary"[^>]*>Record expense/)
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

      expect(response).to redirect_to(portfolio_url)

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
    it "downloads schedule_e_pdf for available year when tax profile exists" do
      create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")
      get schedule_e_pdf_property_url(property, year: 2025)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to match(/attachment/)
    end

    it "redirects and shows alert when tax profile is missing" do
      get schedule_e_pdf_property_url(property, year: 2025)
      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:alert]).to include("Tax classification must be configured for 2025")
    end

    it "redirects and shows alert when unresolved review items exist" do
      Accounting::ChartOfAccounts.ensure_for(user)
      create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")
      unmapped_account = user.accounts.create!(
        name: "Capital Improvements",
        key: "expense_capital_improvements",
        account_type: "expense",
        active: true
      )
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 4, 1),
        description: "New roof installation",
        event_type: "expense_posted"
      )
      create(
        :posting,
        journal_entry: entry,
        account: unmapped_account,
        property: property,
        amount_cents: 800_000
      )

      get schedule_e_pdf_property_url(property, year: 2025)
      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:alert]).to include("Schedule E PDF cannot be generated while 1 unresolved review item(s) exist")
    end

    it "redirects and shows alert for missing schedule_e_pdf template" do
      create(:property_tax_profile, property: property, tax_year: 2026, schedule_e_property_type: "single_family_residence")
      get schedule_e_pdf_property_url(property, year: 2026)
      expect(response).to redirect_to(schedule_e_property_path(property, year: 2026))
      expect(flash[:alert]).to eq("No Schedule E PDF template found for year 2026")
    end

    it "defaults to current year if year parameter is not specified" do
      create(:property_tax_profile, property: property, tax_year: Date.current.year, schedule_e_property_type: "single_family_residence")
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
      expect(response.body).to include("Schedule E — 2026")
      expect(response.body).to include("Multi family residence")
      expect(response.body).to include("Projected Schedule E")
      expect(response.body).to include("Rents received")
      expect(response.body).to include("Not tracked or computed by Yanushi")
    end

    it "shows prompt to configure tax profile when not configured for requested year" do
      get schedule_e_property_url(property, year: 2024)
      expect(response).to be_successful
      expect(response.body).to include("Needs tax profile")
      expect(response.body).to include(new_property_tax_profile_path(property, tax_year: 2024))
    end

    it "redirects with alert on malformed year=garbage without mixing year labels and accounting data" do
      get schedule_e_property_url(property, year: "garbage")
      expect(response).to redirect_to(schedule_e_property_path(property, year: Date.current.year))
      expect(flash[:alert]).to include("Invalid tax year 'garbage'")
    end

    it "redirects with alert on year=0 or negative year" do
      get schedule_e_property_url(property, year: "0")
      expect(response).to redirect_to(schedule_e_property_path(property, year: Date.current.year))
      expect(flash[:alert]).to include("Invalid tax year '0'")
    end

    it "redirects with alert on implausibly distant year" do
      get schedule_e_property_url(property, year: "99999")
      expect(response).to redirect_to(schedule_e_property_path(property, year: Date.current.year))
      expect(flash[:alert]).to include("Invalid tax year '99999'")
    end

    it "renders cross-year reversal review item with original audit link and functioning resolution form" do
      create(:property_tax_profile, property: property, tax_year: 2026, schedule_e_property_type: "single_family_residence")
      tenancy = create(:tenancy, property: property)
      party = create(:party, user: user)
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2025, 1, 1)
      )
      charge = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "other",
        description: "Repair fee",
        amount_cents: 50_000,
        charge_date: Date.new(2025, 6, 1)
      ).value!.data[:charge]
      apply_res = SecurityDepositTransactions::ApplyService.call(
        security_deposit: deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2025, 6, 15)
      )
      orig_entry = apply_res.value!.data[:journal_entry]

      # 2026 reversal of the 2025 deposit_applied
      rev_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2026, 2, 1),
        event_type: "reversal",
        reversal_of: orig_entry,
        source: property
      )
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: 50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: rev_entry, property: property, amount_cents: -50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      get schedule_e_property_url(property, year: 2026)
      expect(response).to be_successful
      expect(response.body).to include("Reversal of unresolved 2025 event")
      expect(response.body).to include("name=\"property_tax_review_resolution[journal_entry_id]\"")
      expect(response.body).to include("value=\"#{orig_entry.id}\"")
      expect(response.body).to include("name=\"property_tax_review_resolution[tax_year]\"")
      expect(response.body).to include("value=\"2025\"")

      # Click "Include in Rents" from the 2026 worksheet
      post property_tax_review_resolutions_path(property), params: {
        return_to_year: 2026,
        property_tax_review_resolution: {
          journal_entry_id: orig_entry.id,
          tax_year: 2025,
          treatment: "include_in_rents"
        }
      }
      expect(response).to redirect_to(schedule_e_property_path(property, year: 2026))

      # Follow redirect and verify 2026 worksheet is now resolved with -$500 on Line 3 and retained review item
      follow_redirect!
      expect(response.body).to include("-$500.00")
      expect(response.body).to include("Resolved")
      expect(response.body).to include("included in Line 3 Rents")
      expect(response.body).to include("Undo")
    end

    it "returns 404 for unowned property" do
      other_user = create(:user)
      other_prop = create(:property, user: other_user)
      get schedule_e_property_url(other_prop)
      expect(response).to have_http_status(:not_found)
    end
  end
end
