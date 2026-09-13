require "rails_helper"

RSpec.describe "Portfolio", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /portfolio" do
    context "when authenticated" do
      before do
        sign_in_as(user)
      end

      it "returns a successful response and renders properties with occupancy and balances" do
        Accounting::ChartOfAccounts.ensure_for(user)
        property = create(:property, user: user, address: "123 Portfolio St")
        unit = create(:rentable_unit, property: property, name: "Unit A")
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

        other_property = create(:property, user: other_user, address: "999 Secret Ave")

        get portfolio_url
        expect(response).to be_successful
        expect(response.body).to include("Portfolio")
        expect(response.body).to include("123 Portfolio St")
        expect(response.body).to include("Occupied")
        expect(response.body).to include("$350.00 due")
        expect(response.body).not_to include("999 Secret Ave")
      end

      it "renders credit for properties with only tenant credits and does not net debt against credit" do
        Accounting::ChartOfAccounts.ensure_for(user)
        credit_property = create(:property, user: user, address: "456 Credit Ave")
        unit_credit = create(:rentable_unit, property: credit_property, name: "Unit C")
        tenancy_credit = create(:tenancy, :month_to_month, rentable_unit: unit_credit, commencement_date: Date.new(2025, 1, 1))
        party = create(:party, user: user, display_name: "Credit Tenant")
        create(:tenancy_party, tenancy: tenancy_credit, party: party)

        Receipts::CreateService.call(
          tenancy: tenancy_credit,
          payer_party: party,
          amount_cents: 886_000,
          received_on: Date.current,
          payment_method: "check"
        )

        get portfolio_url
        expect(response).to be_successful
        expect(response.body).to include("456 Credit Ave")
        expect(response.body).to include("$8,860.00 credit")
      end

      it "renders empty state when user has no properties" do
        get portfolio_url
        expect(response).to be_successful
        expect(response.body).to include("Add your first property")
      end
    end

    context "when unauthenticated" do
      it "redirects to the login page" do
        get portfolio_url
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
