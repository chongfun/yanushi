require "rails_helper"

RSpec.describe "Money", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /money" do
    context "when authenticated" do
      before do
        Accounting::ChartOfAccounts.ensure_for(user)
        sign_in_as(user)
      end

      it "returns a successful response with tabs and portfolio activity" do
        property = create(:property, user: user, address: "742 Evergreen Terrace")
        unit = create(:rentable_unit, property: property)
        tenancy = create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2025, 1, 1))
        create(:rent_term, tenancy: tenancy, amount_cents: 150_000, effective_from: Date.new(2025, 1, 1))
        party = create(:party, user: user, display_name: "Homer Simpson")

        Receipts::CreateService.call(
          tenancy: tenancy,
          payer_party: party,
          amount_cents: 150_000,
          received_on: Date.current,
          payment_method: "check"
        )

        get money_url
        expect(response).to be_successful
        expect(response.body).to include("Money")
        expect(response.body).to include(receipts_path)
        expect(response.body).to include(expenses_path)
        expect(response.body).to include("742 Evergreen Terrace")
        expect(response.body).to include("$1,500.00")
      end

      it "filters activity by property_id" do
        prop1 = create(:property, user: user, address: "111 First St")
        prop2 = create(:property, user: user, address: "222 Second St")
        unit1 = create(:rentable_unit, property: prop1)
        tenancy1 = create(:tenancy, rentable_unit: unit1, commencement_date: Date.new(2025, 1, 1))
        create(:rent_term, tenancy: tenancy1, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1))
        party = create(:party, user: user)

        Receipts::CreateService.call(
          tenancy: tenancy1,
          payer_party: party,
          amount_cents: 100_000,
          received_on: Date.new(2025, 6, 1),
          payment_method: "check"
        )

        get money_url, params: { property_id: prop2.id }
        expect(response).to be_successful
        expect(response.body).to include("No financial activity found")
      end

      it "filters activity by year" do
        prop = create(:property, user: user, address: "333 Third St")
        unit = create(:rentable_unit, property: prop)
        tenancy = create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2024, 1, 1))
        create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.new(2024, 1, 1))
        party = create(:party, user: user)

        Receipts::CreateService.call(
          tenancy: tenancy,
          payer_party: party,
          amount_cents: 100_000,
          received_on: Date.new(2024, 6, 1),
          payment_method: "check"
        )
        Receipts::CreateService.call(
          tenancy: tenancy,
          payer_party: party,
          amount_cents: 200_000,
          received_on: Date.new(2025, 6, 1),
          payment_method: "check"
        )

        get money_url, params: { year: "2024" }
        expect(response).to be_successful
        expect(response.body).to include("$1,000.00")
        expect(response.body).not_to include("$2,000.00")

        get money_url, params: { year: "2025" }
        expect(response).to be_successful
        expect(response.body).to include("$2,000.00")
        expect(response.body).not_to include("$1,000.00")
      end

      it "enforces cross-user isolation" do
        other_prop = create(:property, user: other_user, address: "999 Secret Ave")
        get money_url
        expect(response.body).not_to include("999 Secret Ave")
      end
    end

    context "when unauthenticated" do
      it "redirects to the login page" do
        get money_url
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
