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

      context "period totals" do
        let!(:prop1) { create(:property, user: user, address: "111 First St") }
        let!(:prop2) { create(:property, user: user, address: "222 Second St") }
        let(:unit1) { create(:rentable_unit, property: prop1) }
        let(:tenancy1) { create(:tenancy, rentable_unit: unit1, commencement_date: Date.new(2025, 1, 1)) }
        let(:party) { create(:party, user: user, display_name: "Homer Simpson") }

        before do
          create(:rent_term, tenancy: tenancy1, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1))

          # Income recognized, no cash: $2,000 rent charge.
          Charges::CreateService.call(
            tenancy: tenancy1,
            charge_kind: "rent",
            amount_cents: 200_000,
            charge_date: Date.new(2026, 3, 1)
          )
          # Cash in, no income: $1,500 payment.
          Receipts::CreateService.call(
            tenancy: tenancy1,
            payer_party: party,
            amount_cents: 150_000,
            received_on: Date.new(2026, 3, 5),
            payment_method: "check"
          )
          # $400 operating expense on the first property.
          Expenses::CreateService.call(
            property: prop1,
            expense_kind: "repairs",
            paid_on: Date.new(2026, 3, 10),
            amount_cents: 40_000
          )
          # $250 operating expense on the second property.
          Expenses::CreateService.call(
            property: prop2,
            expense_kind: "insurance",
            paid_on: Date.new(2026, 4, 1),
            amount_cents: 25_000
          )
        end

        it "summarizes income, expenses, net income, and net cash movement for the filter" do
          get money_url, params: { year: "2026" }

          expect(response).to be_successful
          expect(response.body).to include("Income")
          expect(response.body).to include("Expenses")
          expect(response.body).to include("Net income")
          expect(response.body).to include("Net cash movement")

          expect(response.body).to include("$2,000.00")   # income recognized
          expect(response.body).to include("$650.00")     # $400 + $250 expenses
          expect(response.body).to include("$1,350.00")   # net income
          expect(response.body).to include("$850.00")     # $1,500 in - $650 out
        end

        it "recomputes the totals for the selected property" do
          get money_url, params: { year: "2026", property_id: prop2.id }

          expect(response).to be_successful
          expect(response.body).to include("$250.00")
          expect(response.body).to include("−$250.00") # net income and net cash are negative
          expect(response.body).not_to include("$2,000.00")
        end

        it "recomputes the totals for the selected year" do
          get money_url, params: { year: "2025" }

          expect(response).to be_successful
          expect(response.body).to include("Net cash movement")
          expect(response.body).to include("$0.00")
          expect(response.body).not_to include("$650.00")
        end

        it "reports an invalid range instead of totalling it" do
          get money_url, params: { from: "2026-12-31", through: "2026-01-01" }

          expect(response).to be_successful
          expect(response.body).to include("From date cannot be after through date")
          expect(response.body).not_to include("Net cash movement")
        end
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
