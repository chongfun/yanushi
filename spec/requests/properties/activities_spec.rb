require "rails_helper"

RSpec.describe "Properties::Activities", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let!(:tenancy) do
    create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2025, 1, 1))
  end
  let!(:rent_term) do
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1))
  end
  let(:party) { create(:party, user: user, display_name: "Jane Smith") }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
    create(:tenancy_party, tenancy: tenancy, party: party)
  end

  describe "GET /properties/:property_id/activity" do
    context "when authenticated as property owner" do
      before { sign_in_as(user) }

      it "renders 200 OK with activity and filter controls" do
        Charges::CreateService.call(
          tenancy: tenancy,
          charge_kind: "rent",
          amount_cents: 200_000,
          charge_date: Date.current
        )

        get property_activity_path(property)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Rent")
        expect(response.body).to include("$2,000.00")
        expect(response.body).to include("date-range-filter")
      end

      it "respects date filtering parameters" do
        Charges::CreateService.call(
          tenancy: tenancy,
          charge_kind: "rent",
          amount_cents: 200_000,
          charge_date: Date.new(2025, 6, 1)
        )

        get property_activity_path(property, from: "2026-01-01", through: "2026-12-31")
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Jun 1")
      end

      it "handles invalid date range with a flash alert" do
        get property_activity_path(property, from: "2026-12-31", through: "2026-01-01")
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("From date cannot be after through date")
      end
    end

    context "when authenticated as another user" do
      before { sign_in_as(other_user) }

      it "returns 404 Not Found" do
        get property_activity_path(property)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when unauthenticated" do
      it "redirects to login" do
        get property_activity_path(property)
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
