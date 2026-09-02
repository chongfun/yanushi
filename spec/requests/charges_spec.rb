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
  let(:party) { create(:party, user: user) }
  let!(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: tenancy.commencement_date) }

  before do
    sign_in_as(user)
  end

  describe "GET /tenancies/:tenancy_id/charges/new" do
    it "renders a successful response" do
      get new_tenancy_charge_path(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("Add charge")
    end

    it "rejects accessing new charge for another user's tenancy" do
      get new_tenancy_charge_path(other_tenancy)
      expect(response).to have_http_status(:not_found)
    end

    it "renders new charge form with constant queries regardless of participant count" do
      get new_tenancy_charge_path(tenancy)

      queries = []
      counter = ->(_name, _started, _finished, _unique_id, data) {
        queries << data[:sql] unless data[:name].in?(%w[SCHEMA CACHE]) || data[:sql].match?(/\A\s*(SAVEPOINT|ROLLBACK|COMMIT|BEGIN)/i)
      }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get new_tenancy_charge_path(tenancy)
      end
      baseline_count = queries.size

      5.times do |i|
        p = create(:party, user: user, display_name: "Co-tenant #{i}")
        create(:tenancy_party, tenancy: tenancy, party: p, role: "tenant", effective_from: tenancy.commencement_date)
      end

      queries = []
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get new_tenancy_charge_path(tenancy)
      end
      expect(queries.size).to eq(baseline_count)
      expect(response).to be_successful
    end
  end

  describe "POST /tenancies/:tenancy_id/charges" do
    it "creates and posts a late fee charge via format: :html with 303 see_other" do
      expect {
        post tenancy_charges_path(tenancy, format: :html), params: {
          charge: {
            charge_kind: "late_fee",
            amount: "75.00",
            charge_date: Date.current,
            due_on: Date.current,
            description: "Late fee for overdue rent"
          }
        }
      }.to change(Charge, :count).by(1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(tenancy_path(tenancy))
      expect(flash[:notice]).to eq("Charge was successfully created.")
      charge = Charge.last
      expect(charge.amount_cents).to eq(7500)
      expect(charge.charge_kind).to eq("late_fee")
      expect(charge).to be_posted
    end

    it "renders 422 unprocessable_content on invalid standalone format: :html submission and preserves .html action URL" do
      expect {
        post tenancy_charges_path(tenancy, format: :html), params: {
          charge: {
            charge_kind: "late_fee",
            amount: "-10.00",
            charge_date: Date.current,
            due_on: Date.current
          }
        }
      }.not_to change(Charge, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include("Add charge")
      expect(response.body).to match(/action="[^"]*tenancies\/#{tenancy.id}\/charges(\.html|\?format=html)"/)
    end

    it "creates charge via turbo_stream format and returns success" do
      post tenancy_charges_path(tenancy), params: {
        charge: {
          charge_kind: "late_fee",
          amount: "75.00",
          charge_date: Date.current,
          due_on: Date.current,
          description: "Late fee"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("close_modal")
      expect(response.body).to include("tenancy_balance")
      expect(response.body).to include("tenancy_activity")
      expect(response.body).to include("target=\"tenancy_delete_action\"")
      expect(response.body).not_to include("target=\"tenancy_actions\"")
      expect(response.body).to include("target=\"flash-messages\"")
      expect(response.body).to include("Charge posted successfully.")
    end

    it "renders turbo_stream form on error with 422 unprocessable_content" do
      post tenancy_charges_path(tenancy), params: {
        charge: {
          charge_kind: "late_fee",
          amount: "-10.00",
          charge_date: Date.current,
          due_on: Date.current
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include("action=\"update\" target=\"modal-frame\"")
    end

    it "defaults to other when charge_kind is blank" do
      post tenancy_charges_path(tenancy), params: {
        charge: {
          charge_kind: "",
          amount: "25.00",
          charge_date: Date.current,
          due_on: Date.current,
          description: "Key replacement"
        }
      }
      expect(response).to redirect_to(tenancy_path(tenancy))
      expect(Charge.last.charge_kind).to eq("other")
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

    it "renders new with error when service returns failure without charge object" do
      allow(Charges::CreateFeeService).to receive(:call).and_return(
        ServiceResult.failure(error: "Posting error", code: :posting_failed)
      )
      post tenancy_charges_path(tenancy), params: {
        charge: {
          charge_kind: "late_fee",
          amount: "50.00",
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

    it "displays corrected status and replacement link when superseded" do
      correct_res = Charges::CorrectService.call(
        charge: charge,
        amount_cents: 6000
      )
      expect(correct_res).to be_success
      replacement = correct_res.value!.data[:charge]

      # Original charge page shows corrected banner and link to replacement
      get charge_path(charge)
      expect(response).to be_successful
      expect(response.body).to include("Charge Corrected")
      expect(response.body).to include("Corrected (Superseded)")
      expect(response.body).to include("Charge ##{replacement.id}")

      # Replacement charge page shows replacement banner and link to original
      get charge_path(replacement)
      expect(response).to be_successful
      expect(response.body).to include("Replacement Charge")
      expect(response.body).to include("Charge ##{charge.id}")

      # Tenancy show page displays Corrected badge
      get tenancy_path(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("Corrected")
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

    it "renders charge via json" do
      charge = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.current,
        due_on: Date.current,
        description: "Late fee"
      ).value!.data[:charge]

      get charge_path(charge, format: :json)
      expect(response).to be_successful
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

    it "voids the charge without explicit reason using default reason" do
      post void_charge_path(charge)
      expect(response).to redirect_to(tenancy_path(tenancy))
      expect(charge.reload).to be_voided
    end

    it "voids the charge via json" do
      post void_charge_path(charge, format: :json), params: { reason: "Customer dispute" }
      expect(response).to be_successful
      expect(response.parsed_body["status"]).to eq("ok")
    end

    it "handles void failure gracefully" do
      allow(Charges::VoidService).to receive(:call).and_return(
        ServiceResult.failure(error: "Void failed", code: :void_failed)
      )
      post void_charge_path(charge)
      expect(response).to redirect_to(tenancy_path(tenancy))
      expect(flash[:alert]).to include("Failed to void charge")

      post void_charge_path(charge, format: :json)
      expect(response).to have_http_status(:unprocessable_content)
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
