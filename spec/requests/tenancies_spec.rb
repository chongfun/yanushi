require "rails_helper"

RSpec.describe "Tenancies", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:other_property) { create(:property, user: other_user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:other_unit) { create(:rentable_unit, property: other_property) }
  let(:party) { create(:party, user: user) }
  let!(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      agreement_type: "fixed_term",
      commencement_date: Date.current,
      termination_date: Date.current + 1.year
    )
  end
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 150_000,
      effective_from: Date.current,
      effective_until: Date.current + 1.year
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

  describe "GET /tenancies" do
    it "renders a successful response" do
      get tenancies_url
      expect(response).to be_successful
    end
  end

  describe "GET /tenancies/new" do
    it "filters units and parties to only include the current user's" do
      other_party = create(:party, user: other_user, display_name: "Other Party")

      get new_tenancy_url
      expect(response).to be_successful
      expect(response.body).not_to include(other_property.address)
      expect(response.body).not_to include("Other Party")
    end
  end

  describe "POST /tenancies" do
    let(:new_unit) { create(:rentable_unit, property: property, name: "Unit 2") }

    it "creates a tenancy with valid attributes (HTML & JSON)" do
      expect {
        post tenancies_url, params: {
          tenancy: {
            rentable_unit_id: new_unit.id,
            agreement_type: "fixed_term",
            commencement_date: Date.current,
            termination_date: Date.current + 1.year,
            late_period_days: 5,
            party_ids: [ party.id ],
            rent_amount: "1850.00"
          }
        }
      }.to change(Tenancy, :count).by(1)
       .and change(TenancyParty, :count).by(1)
       .and change(RentTerm, :count).by(1)

      expect(response).to redirect_to(tenancy_url(Tenancy.last))

      another_unit = create(:rentable_unit, property: property, name: "Unit 3")
      post tenancies_url(format: :json), params: {
        tenancy: {
          rentable_unit_id: another_unit.id,
          agreement_type: "month_to_month",
          commencement_date: Date.current,
          party_ids: [ party.id ],
          rent_amount: "1200.00"
        }
      }
      expect(response).to have_http_status(:created)

      unit4 = create(:rentable_unit, property: property, name: "Unit 4")
      post tenancies_url, params: {
        tenancy: {
          rentable_unit_id: unit4.id,
          agreement_type: "month_to_month",
          commencement_date: Date.current,
          participants: [
            { party_id: party.id, role: "tenant", effective_from: Date.current }
          ],
          initial_rent: {
            amount_cents: 140_000,
            due_day: 1,
            frequency: "monthly",
            effective_from: Date.current
          }
        }
      }
      expect(response).to redirect_to(tenancy_url(Tenancy.last))

      unit5 = create(:rentable_unit, property: property, name: "Unit 5")
      post tenancies_url, params: {
        tenancy: {
          rentable_unit_id: unit5.id,
          agreement_type: "month_to_month",
          commencement_date: Date.current,
          party_ids: [ party.id ],
          rent_amount_cents: 160_000
        }
      }
      expect(response).to redirect_to(tenancy_url(Tenancy.last))
    end

    it "should not create tenancy with other user's unit" do
      expect {
        post tenancies_url, params: {
          tenancy: {
            rentable_unit_id: other_unit.id,
            agreement_type: "fixed_term",
            commencement_date: Date.current,
            termination_date: Date.current + 1.year,
            party_ids: [ party.id ],
            rent_amount: "1500.00"
          }
        }
      }.not_to change(Tenancy, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "should not create tenancy with other user's party" do
      other_party = create(:party, user: other_user)

      expect {
        post tenancies_url, params: {
          tenancy: {
            rentable_unit_id: new_unit.id,
            agreement_type: "fixed_term",
            commencement_date: Date.current,
            termination_date: Date.current + 1.year,
            party_ids: [ other_party.id ],
            rent_amount: "1500.00"
          }
        }
      }.not_to change(Tenancy, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "renders new on validation failure (HTML & JSON)" do
      expect {
        post tenancies_url, params: {
          tenancy: {
            rentable_unit_id: new_unit.id,
            party_ids: [ party.id ],
            agreement_type: "fixed_term",
            commencement_date: Date.current,
            termination_date: nil
          }
        }
      }.not_to change(Tenancy, :count)

      expect(response).to have_http_status(:unprocessable_content)

      post tenancies_url(format: :json), params: {
        tenancy: {
          rentable_unit_id: new_unit.id,
          party_ids: [ party.id ],
          agreement_type: "fixed_term",
          commencement_date: Date.current,
          termination_date: nil
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "handles creating tenancy with empty party_ids" do
      post tenancies_url, params: {
        tenancy: {
          rentable_unit_id: new_unit.id,
          agreement_type: "fixed_term",
          commencement_date: Date.current,
          termination_date: Date.current + 1.year,
          party_ids: [],
          rent_amount: "1500.00"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /tenancies/:id" do
    it "renders a successful response" do
      get tenancy_url(tenancy)
      expect(response).to be_successful
    end
  end

  describe "GET /tenancies/:id/edit" do
    it "renders a successful response" do
      get edit_tenancy_url(tenancy)
      expect(response).to be_successful
    end
  end

  describe "PATCH /tenancies/:id" do
    it "updates the tenancy and redirects (HTML & JSON)" do
      patch tenancy_url(tenancy), params: { tenancy: { late_period_days: 10 } }
      expect(response).to redirect_to(tenancy_url(tenancy))
      expect(tenancy.reload.late_period_days).to eq(10)

      patch tenancy_url(tenancy, format: :json), params: { tenancy: { late_period_days: 15 } }
      expect(response).to have_http_status(:ok)
    end

    it "renders edit on validation failure (HTML & JSON)" do
      patch tenancy_url(tenancy), params: { tenancy: { termination_date: Date.current - 1.month } }
      expect(response).to have_http_status(:unprocessable_content)

      patch tenancy_url(tenancy, format: :json), params: { tenancy: { termination_date: Date.current - 1.month } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /tenancies/:id" do
    it "destroys a pristine tenancy and redirects (HTML & JSON)" do
      expect {
        delete tenancy_url(tenancy)
      }.to change(Tenancy, :count).by(-1)

      expect(response).to redirect_to(tenancies_url)

      second_unit = create(:rentable_unit, property: property, name: "Second Unit")
      second_tenancy = create(:tenancy, rentable_unit: second_unit)
      delete tenancy_url(second_tenancy, format: :json)
      expect(response).to have_http_status(:no_content)
    end

    it "prevents deleting a tenancy with financial history (HTML & JSON)" do
      create(:receipt, tenancy: tenancy, amount_cents: 150_000, received_on: Date.current)

      expect {
        delete tenancy_url(tenancy)
      }.not_to change(Tenancy, :count)

      expect(response).to redirect_to(tenancy_url(tenancy))
      follow_redirect!
      expect(response.body).to include("Cannot delete record because dependent receipts exist")

      delete tenancy_url(tenancy, format: :json)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
