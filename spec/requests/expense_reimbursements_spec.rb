require "rails_helper"

RSpec.describe "ExpenseReimbursements", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit1) { create(:rentable_unit, property: property, name: "Unit A") }
  let(:unit2) { create(:rentable_unit, property: property, name: "Unit B") }
  let(:tenancy1) { create(:tenancy, rentable_unit: unit1) }
  let(:tenancy2) { create(:tenancy, rentable_unit: unit2) }
  let(:expense) { create(:expense, property: property, amount: 300.0) }

  let(:other_user) { create(:user) }
  let(:other_property) { create(:property, user: other_user) }
  let(:other_unit) { create(:rentable_unit, property: other_property) }
  let(:other_tenancy) { create(:tenancy, rentable_unit: other_unit) }
  let(:other_expense) { create(:expense, property: other_property, amount: 200.0) }

  before do
    sign_in_as(user)
  end

  describe "GET /expenses/:expense_id/reimbursements/new" do
    it "renders a successful response" do
      get new_expense_reimbursement_path(expense)
      expect(response).to be_successful
      expect(response.body).to include("Add Reimbursement Charge")
    end

    it "redirects when expense is already fully reimbursed" do
      Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy1,
        amount: 300.0,
        charge_date: Date.current,
        due_on: Date.current
      )

      get new_expense_reimbursement_path(expense)
      expect(response).to redirect_to(expense_path(expense))
      expect(flash[:alert]).to include("already been fully reimbursed")
    end
  end

  describe "POST /expenses/:expense_id/reimbursements" do
    it "creates a reimbursement charge for a tenancy on the same property" do
      expect {
        post expense_reimbursements_path(expense), params: {
          charge: {
            tenancy_id: tenancy1.id,
            amount: "150.00",
            charge_date: Date.current,
            due_on: Date.current,
            description: "Water bill - Unit A share"
          }
        }
      }.to change(Charge, :count).by(1)

      expect(response).to redirect_to(expense_path(expense))
      charge = Charge.last
      expect(charge.charge_kind).to eq("reimbursement")
      expect(charge.amount_cents).to eq(15000)
      expect(charge.source_expense).to eq(expense)
      expect(charge.tenancy).to eq(tenancy1)
    end

    it "rejects reimbursement amount exceeding remaining reimbursable amount" do
      post expense_reimbursements_path(expense), params: {
        charge: {
          tenancy_id: tenancy1.id,
          amount: "400.00",
          charge_date: Date.current,
          due_on: Date.current
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("exceeds remaining reimbursable amount")
    end

    it "allows creating multiple reimbursement charges for different tenancies on the same expense" do
      Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy1,
        amount: 150.0,
        charge_date: Date.current,
        due_on: Date.current,
        description: "Unit A share"
      )

      expect {
        post expense_reimbursements_path(expense), params: {
          charge: {
            tenancy_id: tenancy2.id,
            amount: "150.00",
            charge_date: Date.current,
            due_on: Date.current,
            description: "Unit B share"
          }
        }
      }.to change(Charge, :count).by(1)

      expect(expense.reload.reimbursement_charges.count).to eq(2)
    end

    it "rejects creating a reimbursement charge for a tenancy on a different property" do
      expect {
        post expense_reimbursements_path(expense), params: {
          charge: {
            tenancy_id: other_tenancy.id,
            amount: "150.00",
            charge_date: Date.current,
            due_on: Date.current
          }
        }
      }.not_to change(Charge, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "renders new with 422 when tenancy is missing" do
      post expense_reimbursements_path(expense), params: {
        charge: {
          tenancy_id: "",
          amount: "150.00",
          charge_date: Date.current,
          due_on: Date.current
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "renders new with 422 on service validation error" do
      post expense_reimbursements_path(expense), params: {
        charge: {
          tenancy_id: tenancy1.id,
          amount: "-50.00",
          charge_date: Date.current,
          due_on: Date.current
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
