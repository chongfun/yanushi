require "rails_helper"

RSpec.describe "ExpenseReimbursements", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit1) { create(:rentable_unit, property: property) }
  let(:unit2) { create(:rentable_unit, property: property) }
  let(:tenancy1) { create(:tenancy, rentable_unit: unit1) }
  let(:tenancy2) { create(:tenancy, rentable_unit: unit2) }
  let(:expense) { create(:expense, :posted, property: property, amount_cents: 30_000) }

  let(:other_user) { create(:user) }
  let(:other_property) { create(:property, user: other_user) }
  let(:other_unit) { create(:rentable_unit, property: other_property) }
  let(:other_tenancy) { create(:tenancy, rentable_unit: other_unit) }
  let(:other_expense) { create(:expense, :posted, property: other_property, amount_cents: 20_000) }

  before do
    sign_in_as(user)
  end

  describe "GET /expenses/:expense_id/reimbursements/new" do
    it "renders a successful response" do
      get new_expense_reimbursement_path(expense)
      expect(response).to be_successful
      expect(response.body).to include("Add reimbursement charge")
    end

    it "redirects when expense is already fully reimbursed" do
      Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy1,
        amount_cents: 30_000,
        charge_date: Date.current,
        due_on: Date.current
      )

      get new_expense_reimbursement_path(expense)
      expect(response).to redirect_to(expense_path(expense))
      expect(flash[:alert]).to include("already been fully reimbursed")
    end

    it "redirects when expense is voided or superseded" do
      voided_exp = create(:expense, :voided, property: property, amount_cents: 10_000)
      get new_expense_reimbursement_path(voided_exp)
      expect(response).to redirect_to(expense_path(voided_exp))
      expect(flash[:alert]).to include("Cannot reimburse a voided or corrected expense")
    end

    it "renders new successfully for unit-scoped expense" do
      unit_exp = create(:expense, :posted, property: property, rentable_unit: unit1, amount_cents: 10_000)
      get new_expense_reimbursement_path(unit_exp)
      expect(response).to be_successful
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
            description: "Water bill - Unit 1 share"
          }
        }
      }.to change(Charge, :count).by(1)

      expect(response).to redirect_to(expense_path(expense))
      charge = Charge.last
      expect(charge.charge_kind).to eq("reimbursement")
      expect(charge.amount_cents).to eq(15_000)
      expect(charge.source_expense).to eq(expense)
      expect(charge.tenancy).to eq(tenancy1)
    end

    it "ignores submitted amount_cents parameter and creates with amount" do
      expect {
        post expense_reimbursements_path(expense), params: {
          charge: {
            tenancy_id: tenancy1.id,
            amount: "150.00",
            amount_cents: 1,
            charge_date: Date.current,
            due_on: Date.current,
            description: "Water bill - Unit 1 share"
          }
        }
      }.to change(Charge, :count).by(1)

      charge = Charge.last
      expect(charge.amount_cents).to eq(15_000)
      expect(charge.amount).to eq(150.00)
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
        amount_cents: 15_000,
        charge_date: Date.current,
        due_on: Date.current,
        description: "Unit 1 share"
      )

      expect {
        post expense_reimbursements_path(expense), params: {
          charge: {
            tenancy_id: tenancy2.id,
            amount: "150.00",
            charge_date: Date.current,
            due_on: Date.current,
            description: "Unit 2 share"
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

    it "creates a reimbursement for a unit-scoped expense" do
      unit_exp = create(:expense, :posted, property: property, rentable_unit: unit1, amount_cents: 10_000)
      post expense_reimbursements_path(unit_exp), params: {
        charge: {
          tenancy_id: tenancy1.id,
          amount: "50.00",
          charge_date: Date.current,
          due_on: Date.current
        }
      }
      expect(response).to redirect_to(expense_path(unit_exp))
      expect(unit_exp.reload.reimbursement_charges.count).to eq(1)
    end
  end
end
