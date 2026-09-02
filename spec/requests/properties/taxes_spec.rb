require "rails_helper"

RSpec.describe "Properties::Taxes", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
  end

  describe "GET /properties/:property_id/tax" do
    context "when authenticated as property owner" do
      before { sign_in_as(user) }

      it "renders 200 OK with primary tax profile setup button when none exists for default year" do
        get property_tax_path(property)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No tax profile exists")
        expect(response.body).to include(new_property_tax_profile_path(property, tax_year: Date.current.year))
        expect(response.body).to match(/class="yn-btn yn-btn-primary[^"]*"[^>]*>Set up #{Date.current.year} tax profile/)
      end

      it "renders setup CTA with tax_year param for non-current year and leads to matching new profile form" do
        get property_tax_path(property, year: 2025)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No tax profile exists for 2025")
        expect(response.body).to include(new_property_tax_profile_path(property, tax_year: 2025))
        expect(response.body).to match(/class="yn-btn yn-btn-primary[^"]*"[^>]*>Set up 2025 tax profile/)

        get new_property_tax_profile_path(property, tax_year: 2025)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("2025")
        expect(response.body).to include("value=\"2025\"")
      end

      it "renders 200 OK with View Schedule E and Download PDF when profile exists and PDF template is available" do
        create(
          :property_tax_profile,
          property: property,
          tax_year: 2025,
          schedule_e_property_type: "single_family_residence"
        )

        get property_tax_path(property, year: 2025)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Single family residence")
        expect(response.body).to include("Schedule E, 2025")
        expect(response.body).to include("Ready")
        expect(response.body).to include("View Schedule E")
        expect(response.body).to include("Download PDF")
        expect(response.body).not_to include("PDF export isn’t available")
      end

      it "renders Review Schedule E when profile exists and items need review" do
        create(
          :property_tax_profile,
          property: property,
          tax_year: 2025,
          schedule_e_property_type: "single_family_residence"
        )
        unmapped_account = user.accounts.create!(name: "Custom Roof", key: "expense_custom_roof_tax_tab", account_type: "expense")
        expense = create(:expense, property: property)
        expense_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "expense_posted", source: expense)
        create(:posting, journal_entry: expense_entry, property: property, amount_cents: 300_000, account: unmapped_account)

        get property_tax_path(property, year: 2025)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Single family residence")
        expect(response.body).to include("1 item needs review")
        expect(response.body).to include("Review Schedule E")
        expect(response.body).to include(schedule_e_property_path(property, year: 2025))
      end

      it "renders 200 OK with View Schedule E and unavailable export notice when PDF template is missing" do
        create(
          :property_tax_profile,
          property: property,
          tax_year: 2026,
          schedule_e_property_type: "single_family_residence"
        )

        get property_tax_path(property, year: 2026)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Single family residence")
        expect(response.body).to include("Schedule E, 2026")
        expect(response.body).to include("Ready")
        expect(response.body).to include("View Schedule E")
        expect(response.body).to include("PDF export isn’t available for 2026.")
        expect(response.body).not_to include("Download PDF")
      end

      it "handles invalid non-blank year parameter by falling back cleanly" do
        get property_tax_path(property, year: "invalid-year")
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No tax profile exists for #{Date.current.year}")
      end

      it "renders Record expense as secondary button on Tax tab" do
        get property_tax_path(property)
        expect(response).to have_http_status(:ok)
        expect(response.body).to match(/class="yn-btn yn-btn-secondary"[^>]*>Record expense/)
      end
    end

    context "when authenticated as another user" do
      before { sign_in_as(other_user) }

      it "returns 404 Not Found" do
        get property_tax_path(property)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when unauthenticated" do
      it "redirects to login" do
        get property_tax_path(property)
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
