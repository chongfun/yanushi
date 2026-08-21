require "rails_helper"

RSpec.describe "RentTerms", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      agreement_type: "month_to_month",
      commencement_date: Date.new(2025, 1, 1),
      termination_date: nil
    )
  end
  let!(:initial_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 180_000,
      effective_from: Date.new(2025, 1, 1),
      effective_until: nil
    )
  end

  before do
    sign_in_as(user)
  end

  describe "GET /tenancies/:tenancy_id/rent_terms/new" do
    it "renders a successful response when tenancy has an existing rent term" do
      get new_tenancy_rent_term_url(tenancy)
      expect(response).to be_successful
    end

    it "renders a successful response when tenancy has no rent terms" do
      empty_unit = create(:rentable_unit, property: property, name: "Empty Unit")
      empty_tenancy = create(:tenancy, rentable_unit: empty_unit, agreement_type: "month_to_month", commencement_date: Date.current, termination_date: nil)
      get new_tenancy_rent_term_url(empty_tenancy)
      expect(response).to be_successful
    end
  end

  describe "POST /tenancies/:tenancy_id/rent_terms" do
    it "creates a new rent term and updates prior term (HTML & JSON)" do
      future_date_1 = (Date.current + 2.months).beginning_of_month
      future_date_2 = (Date.current + 4.months).beginning_of_month
      future_date_3 = (Date.current + 6.months).beginning_of_month

      expect {
        post tenancy_rent_terms_url(tenancy), params: {
          rent_term: {
            amount: "1950.00",
            due_day: 1,
            frequency: "monthly",
            effective_from: future_date_1
          }
        }
      }.to change(RentTerm, :count).by(1)

      expect(response).to redirect_to(tenancy_url(tenancy))
      expect(initial_term.reload.effective_until).to eq(future_date_1 - 1.day)

      post tenancy_rent_terms_url(tenancy), params: {
        rent_term: {
          amount_cents: 210_000,
          due_day: 1,
          frequency: "monthly",
          effective_from: future_date_2
        }
      }
      expect(response).to redirect_to(tenancy_url(tenancy))

      post tenancy_rent_terms_url(tenancy, format: :json), params: {
        rent_term: {
          amount_cents: 220_000,
          due_day: 1,
          frequency: "monthly",
          effective_from: future_date_3
        }
      }
      expect(response).to have_http_status(:created)
    end

    it "renders new on validation failure (HTML & JSON)" do
      expect {
        post tenancy_rent_terms_url(tenancy), params: {
          rent_term: {
            amount: "",
            effective_from: ""
          }
        }
      }.not_to change(RentTerm, :count)

      expect(response).to have_http_status(:unprocessable_content)

      post tenancy_rent_terms_url(tenancy, format: :json), params: {
        rent_term: {
          amount: "",
          effective_from: ""
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "renders new when change service returns non-model failure" do
      allow(RentTerms::ChangeService).to receive(:call).and_return(
        ServiceResult.failure(error: "Custom service error", code: :invalid)
      )

      post tenancy_rent_terms_url(tenancy), params: {
        rent_term: {
          amount: "1500.00",
          effective_from: Date.current
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
