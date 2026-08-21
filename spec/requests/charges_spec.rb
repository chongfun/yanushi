require "rails_helper"

RSpec.describe "Charges", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:other_user) { create(:user) }
  let(:other_property) { create(:property, user: other_user) }
  let(:other_unit) { create(:rentable_unit, property: other_property) }
  let(:other_tenancy) { create(:tenancy, rentable_unit: other_unit) }

  before do
    sign_in_as(user)
  end

  describe "GET /tenancies/:tenancy_id/charges/new" do
    it "renders a successful response" do
      get new_tenancy_charge_path(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("Add Charge")
    end

    it "rejects accessing new charge for another user's tenancy" do
      get new_tenancy_charge_path(other_tenancy)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /tenancies/:tenancy_id/charges" do
    it "creates and posts a late fee charge" do
      expect {
        post tenancy_charges_path(tenancy), params: {
          charge: {
            charge_kind: "late_fee",
            amount: "75.00",
            charge_date: Date.current,
            due_on: Date.current,
            description: "Late fee for overdue rent"
          }
        }
      }.to change(Charge, :count).by(1)

      expect(response).to redirect_to(tenancy_path(tenancy))
      charge = Charge.last
      expect(charge.amount_cents).to eq(7500)
      expect(charge.charge_kind).to eq("late_fee")
      expect(charge).to be_posted
    end

    it "renders new on validation error" do
      post tenancy_charges_path(tenancy), params: {
        charge: {
          charge_kind: "late_fee",
          amount: "-10.00",
          charge_date: Date.current,
          due_on: Date.current
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "handles malformed amount gracefully without 500" do
      post tenancy_charges_path(tenancy), params: {
        charge: {
          charge_kind: "late_fee",
          amount: "not-money",
          charge_date: Date.current,
          due_on: Date.current
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects manual rent charge creation" do
      post tenancy_charges_path(tenancy), params: {
        charge: {
          charge_kind: "rent",
          amount: "1000.00",
          charge_date: Date.current,
          due_on: Date.current
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must be late_fee or other")
    end

    it "rejects manual reimbursement charge creation through fee endpoint" do
      post tenancy_charges_path(tenancy), params: {
        charge: {
          charge_kind: "reimbursement",
          amount: "100.00",
          charge_date: Date.current,
          due_on: Date.current
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must be late_fee or other")
    end

    it "rejects creating charge on another user's tenancy" do
      post tenancy_charges_path(other_tenancy), params: {
        charge: {
          charge_kind: "late_fee",
          amount: "50.00",
          charge_date: Date.current,
          due_on: Date.current
        }
      }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /charges/:id" do
    let(:charge) do
      result = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.current,
        due_on: Date.current,
        description: "Late fee"
      )
      result.value!.data[:charge]
    end

    it "renders a successful response" do
      get charge_path(charge)
      expect(response).to be_successful
      expect(response.body).to include("Charge Details")
      expect(response.body).to include("$50.00")
    end

    it "rejects viewing another user's charge" do
      other_charge = Charges::CreateFeeService.call(
        tenancy: other_tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.current,
        due_on: Date.current,
        description: "Late fee"
      ).value!.data[:charge]

      get charge_path(other_charge)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /charges/:id/void" do
    let(:charge) do
      Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.current,
        due_on: Date.current,
        description: "Late fee"
      ).value!.data[:charge]
    end

    it "voids the charge and redirects to tenancy" do
      post void_charge_path(charge), params: { reason: "Customer dispute" }
      expect(response).to redirect_to(tenancy_path(tenancy))
      expect(charge.reload).to be_voided
    end

    it "rejects voiding another user's charge" do
      other_charge = Charges::CreateFeeService.call(
        tenancy: other_tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.current,
        due_on: Date.current,
        description: "Late fee"
      ).value!.data[:charge]

      post void_charge_path(other_charge)
      expect(response).to have_http_status(:not_found)
      expect(other_charge.reload).not_to be_voided
    end
  end
end
