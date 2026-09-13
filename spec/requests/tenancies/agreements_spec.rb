require "rails_helper"

RSpec.describe "Tenancies::Agreements", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let!(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      agreement_type: "fixed_term",
      commencement_date: Date.current.beginning_of_month,
      termination_date: Date.current.beginning_of_month + 1.year,
      late_period_days: 5
    )
  end
  let!(:party) { create(:party, user: user, display_name: "Alice Walker") }
  let!(:tenancy_party) do
    create(:tenancy_party,
      tenancy: tenancy,
      party: party,
      role: "tenant",
      effective_from: tenancy.commencement_date,
      effective_until: tenancy.termination_date
    )
  end
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 200_000,
      effective_from: tenancy.commencement_date,
      effective_until: tenancy.termination_date
    )
  end

  before do
    sign_in_as(user)
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe "GET /tenancies/:tenancy_id/agreement" do
    it "renders a successful response with agreement sections" do
      get tenancy_agreement_path(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("Terms")
      expect(response.body).to include("Participants")
      expect(response.body).to include("Rent")
      expect(response.body).to include("Security deposit")
    end

    it "displays tenant name and agreement details" do
      get tenancy_agreement_path(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("Alice Walker")
      expect(response.body).to include("Fixed term")
      expect(response.body).to include("5 days")
    end

    it "displays rent term with Current status badge" do
      get tenancy_agreement_path(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("$2,000.00")
      expect(response.body).to include("Current")
    end

    it "shows deposit setup link when no deposit configured" do
      get tenancy_agreement_path(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("Set up deposit")
      expect(response.body).to include("No security deposit requirement recorded")
    end

    it "shows deposit details when deposit is configured" do
      create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      get tenancy_agreement_path(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("Required")
      expect(response.body).to include("$2,000.00")
      expect(response.body).to include("Currently held")
    end

    it "rejects accessing another user's tenancy agreement" do
      other_user = create(:user)
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)

      get tenancy_agreement_path(other_tenancy)
      expect(response).to have_http_status(:not_found)
    end
  end
end
