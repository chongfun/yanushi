require "rails_helper"

RSpec.describe "Dashboards", type: :request do
  let(:user) { create(:user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe "GET /" do
    context "when authenticated" do
      before do
        sign_in_as(user)
      end

      it "renders the overview page successfully with all sections" do
        get root_url
        expect(response).to be_successful
        expect(response.body).to include("Overview")
        expect(response.body).to include("Needs attention")
        expect(response.body).to include("Nothing needs attention.")
        expect(response.body).to include("Portfolio summary")
        expect(response.body).to include("Properties")
        expect(response.body).to include("Recent activity")
      end

      it "renders attention items when attention is needed" do
        property = create(:property, user: user, address: "123 Main St")
        unit = create(:rentable_unit, property: property, name: "Unit 1")
        tenancy = create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2025, 1, 1))
        create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1))
        party = create(:party, user: user, display_name: "Jane Smith")
        create(:tenancy_party, tenancy: tenancy, party: party)

        Charges::CreateService.call(
          tenancy: tenancy,
          charge_kind: "rent",
          amount_cents: 35_000,
          charge_date: Date.current
        )

        get root_url
        expect(response).to be_successful
        expect(response.body).to include("Jane Smith owes $350.00")
        expect(response.body).to include(tenancy_path(tenancy))
      end
    end

    context "when unauthenticated" do
      it "redirects to the login page" do
        get root_url
        expect(response).to redirect_to(new_session_path)
      end
    end
  end

  describe "authenticated? helper method" do
    context "when authenticated" do
      before { sign_in_as(user) }

      it "returns true" do
        get root_url
        expect(controller.send(:authenticated?)).to be_truthy
      end
    end

    context "when unauthenticated" do
      it "returns false" do
        get root_url
        expect(controller.send(:authenticated?)).to be_falsey
      end
    end
  end
end
