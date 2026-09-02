require "rails_helper"

RSpec.describe "Properties::Tenancies", type: :request do
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

  describe "GET /properties/:property_id/tenancies" do
    context "when authenticated as property owner" do
      before { sign_in_as(user) }

      it "renders 200 OK with tenancies list" do
        get property_tenancies_path(property)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Jane Smith")
        expect(response.body).to include(property.address)
      end

      it "renders current, upcoming, and past tenancy sections" do
        unit_upcoming = create(:rentable_unit, property: property, name: "Unit Upcoming")
        upcoming_start = Date.current.next_month.beginning_of_month
        upcoming_tenancy = create(:tenancy, :month_to_month, rentable_unit: unit_upcoming, commencement_date: upcoming_start)
        upcoming_party = create(:party, user: user, display_name: "Future Tenant")
        create(:tenancy_party, tenancy: upcoming_tenancy, party: upcoming_party)
        create(:rent_term, tenancy: upcoming_tenancy, amount_cents: 200_000, effective_from: upcoming_start, effective_until: upcoming_start + 4.months)
        create(:rent_term, tenancy: upcoming_tenancy, amount_cents: 220_000, effective_from: upcoming_start + 5.months, effective_until: nil)

        unit_past = create(:rentable_unit, property: property, name: "Unit Past")
        past_tenancy = create(:tenancy, rentable_unit: unit_past, commencement_date: Date.current - 1.year, termination_date: Date.current - 1.month)
        past_party = create(:party, user: user, display_name: "Past Tenant")
        create(:tenancy_party, tenancy: past_tenancy, party: past_party)

        get property_tenancies_path(property)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Current")
        expect(response.body).to include("Upcoming")
        expect(response.body).to include("Past")
        expect(response.body).to include("Jane Smith")
        expect(response.body).to include("Future Tenant")
        expect(response.body).to include("$2,000.00/mo")
        expect(response.body).not_to include("$2,200.00/mo")
        expect(response.body).to include("Past Tenant")
      end

      it "renders a dash for rent when an active tenancy is currently in a legal gap between rent terms" do
        unit_gap = create(:rentable_unit, property: property, name: "Unit Gap")
        gap_tenancy = create(:tenancy, :month_to_month, rentable_unit: unit_gap, commencement_date: Date.current - 6.months)
        gap_party = create(:party, user: user, display_name: "Gap Tenant")
        create(:tenancy_party, tenancy: gap_tenancy, party: gap_party)

        # Past term ended 1 month ago
        create(:rent_term, tenancy: gap_tenancy, amount_cents: 200_000, effective_from: Date.current - 6.months, effective_until: Date.current - 1.month)
        # Future term starts in 1 month
        create(:rent_term, tenancy: gap_tenancy, amount_cents: 220_000, effective_from: Date.current + 1.month, effective_until: nil)

        get property_tenancies_path(property)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Gap Tenant")
        expect(response.body).not_to include("$2,200.00/mo")
      end

      it "resolves active tenant and distinguishes guarantors under tenant replacement" do
        unit_role = create(:rentable_unit, property: property, name: "Unit Role")
        tenancy_role = create(:tenancy, :fixed_term, rentable_unit: unit_role, commencement_date: Date.current - 6.months, termination_date: Date.current + 6.months)
        create(:rent_term, tenancy: tenancy_role, amount_cents: 180_000, effective_from: Date.current - 6.months)

        alice = create(:party, user: user, display_name: "Alice Former")
        bob = create(:party, user: user, display_name: "Bob Current")
        greg = create(:party, user: user, display_name: "Greg Guarantor")

        # Alice tenant past 3 months ago
        create(:tenancy_party, tenancy: tenancy_role, party: alice, role: "tenant", effective_from: Date.current - 6.months, effective_until: Date.current - 3.months)
        # Bob tenant currently
        create(:tenancy_party, tenancy: tenancy_role, party: bob, role: "tenant", effective_from: Date.current - 3.months, effective_until: Date.current + 6.months)
        # Greg guarantor throughout
        create(:tenancy_party, tenancy: tenancy_role, party: greg, role: "guarantor", effective_from: Date.current - 6.months, effective_until: Date.current + 6.months)

        get property_tenancies_path(property)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Bob Current")
        expect(response.body).to include("+ 1 other party")
        expect(response.body).not_to include("Alice Former")
      end
    end

    context "when authenticated as another user" do
      before { sign_in_as(other_user) }

      it "returns 404 Not Found" do
        get property_tenancies_path(property)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when unauthenticated" do
      it "redirects to login" do
        get property_tenancies_path(property)
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
