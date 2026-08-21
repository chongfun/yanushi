require "rails_helper"

RSpec.describe "TenancyParties", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party) { create(:party, user: user) }
  let(:new_party) { create(:party, user: user, display_name: "Guarantor Person") }
  let(:second_tenant_party) { create(:party, user: user, display_name: "Second Tenant") }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      agreement_type: "fixed_term",
      commencement_date: Date.current,
      termination_date: Date.current + 1.year
    )
  end
  let!(:tenancy_party) do
    create(:tenancy_party,
      tenancy: tenancy,
      party: party,
      role: "tenant",
      effective_from: Date.current,
      effective_until: Date.current + 1.year
    )
  end

  before do
    sign_in_as(user)
  end

  describe "GET /tenancies/:tenancy_id/tenancy_parties/new" do
    it "renders a successful response" do
      get new_tenancy_tenancy_party_url(tenancy)
      expect(response).to be_successful
    end
  end

  describe "GET /tenancies/:tenancy_id/tenancy_parties/:id/edit" do
    it "renders a successful response" do
      get edit_tenancy_tenancy_party_url(tenancy, tenancy_party)
      expect(response).to be_successful
    end
  end

  describe "POST /tenancies/:tenancy_id/tenancy_parties" do
    it "creates a new participant on the tenancy (HTML & JSON)" do
      expect {
        post tenancy_tenancy_parties_url(tenancy), params: {
          tenancy_party: {
            party_id: new_party.id,
            role: "guarantor",
            effective_from: Date.current,
            effective_until: Date.current + 1.year
          }
        }
      }.to change(TenancyParty, :count).by(1)

      expect(response).to redirect_to(tenancy_url(tenancy))

      another_party = create(:party, user: user, display_name: "Another Party")
      post tenancy_tenancy_parties_url(tenancy, format: :json), params: {
        tenancy_party: {
          party_id: another_party.id,
          role: "occupant",
          effective_from: Date.current,
          effective_until: Date.current + 1.year
        }
      }
      expect(response).to have_http_status(:created)
    end

    it "renders new on validation failure (HTML & JSON)" do
      expect {
        post tenancy_tenancy_parties_url(tenancy), params: {
          tenancy_party: {
            party_id: new_party.id,
            role: "invalid_role"
          }
        }
      }.not_to change(TenancyParty, :count)

      expect(response).to have_http_status(:unprocessable_content)

      post tenancy_tenancy_parties_url(tenancy, format: :json), params: {
        tenancy_party: {
          party_id: new_party.id,
          role: "invalid_role"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /tenancies/:tenancy_id/tenancy_parties/:id" do
    let!(:second_tenant_party) do
      create(:tenancy_party,
        tenancy: tenancy,
        party: create(:party, user: user, display_name: "Co-Tenant"),
        role: "tenant",
        effective_from: Date.current,
        effective_until: Date.current + 1.year
      )
    end

    it "updates effective_until and ignores immutable attributes like role (HTML & JSON)" do
      patch tenancy_tenancy_party_url(tenancy, tenancy_party), params: {
        tenancy_party: {
          effective_until: Date.current + 6.months,
          role: "guarantor"
        }
      }
      expect(response).to redirect_to(tenancy_url(tenancy))
      expect(tenancy_party.reload.effective_until).to eq(Date.current + 6.months)
      expect(tenancy_party.role).to eq("tenant")

      patch tenancy_tenancy_party_url(tenancy, tenancy_party, format: :json), params: {
        tenancy_party: {
          effective_until: Date.current + 8.months
        }
      }
      expect(response).to have_http_status(:ok)
      expect(tenancy_party.reload.effective_until).to eq(Date.current + 8.months)
    end

    it "prevents shortening effective_until of a sole tenant when it breaks continuous coverage" do
      second_tenant_party.destroy!

      patch tenancy_tenancy_party_url(tenancy, tenancy_party), params: {
        tenancy_party: {
          effective_until: Date.current + 6.months
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(tenancy_party.reload.effective_until).to eq(Date.current + 1.year)
    end

    it "renders edit on validation failure when effective_until is before effective_from" do
      patch tenancy_tenancy_party_url(tenancy, tenancy_party), params: {
        tenancy_party: {
          effective_until: Date.current - 1.day
        }
      }
      expect(response).to have_http_status(:unprocessable_content)

      patch tenancy_tenancy_party_url(tenancy, tenancy_party, format: :json), params: {
        tenancy_party: {
          effective_until: Date.current - 1.day
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /tenancies/:tenancy_id/tenancy_parties/:id" do
    let!(:second_party) do
      create(:tenancy_party,
        tenancy: tenancy,
        party: new_party,
        role: "occupant",
        effective_from: Date.current,
        effective_until: Date.current + 1.year
      )
    end

    it "prevents deleting the sole tenant from the tenancy (HTML & JSON)" do
      expect {
        delete tenancy_tenancy_party_url(tenancy, tenancy_party)
      }.not_to change(TenancyParty, :count)

      expect(response).to redirect_to(tenancy_url(tenancy))
      follow_redirect!
      expect(response.body).to include("tenancy must maintain continuous tenant coverage")

      delete tenancy_tenancy_party_url(tenancy, tenancy_party, format: :json)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "removes non-tenant participant (HTML & JSON)" do
      expect {
        delete tenancy_tenancy_party_url(tenancy, second_party)
      }.to change(TenancyParty, :count).by(-1)

      expect(response).to redirect_to(tenancy_url(tenancy))

      third_party = create(:tenancy_party,
        tenancy: tenancy,
        party: create(:party, user: user),
        role: "occupant",
        effective_from: Date.current,
        effective_until: Date.current + 1.year
      )
      delete tenancy_tenancy_party_url(tenancy, third_party, format: :json)
      expect(response).to have_http_status(:no_content)
    end
  end
end
