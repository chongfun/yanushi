require "rails_helper"

RSpec.describe "Receipts", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2026, 1, 1)) }
  let(:party) { create(:party, user: user, display_name: "Alice Walker") }
  let!(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant") }

  before do
    sign_in_as(user)
  end

  describe "GET /receipts" do
    it "renders a successful list of user's receipts" do
      create(:receipt, tenancy: tenancy, payer_party: party, user: user, amount_cents: 100_000)
      get receipts_url
      expect(response).to be_successful
      expect(response.body).to include("Receipts")
      expect(response.body).to include("Alice Walker")
    end

    it "does not display other user's receipts" do
      other_party = create(:party, user: other_user, display_name: "Other Payer")
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      create(:receipt, tenancy: other_tenancy, payer_party: other_party, user: other_user)

      get receipts_url
      expect(response).to be_successful
      expect(response.body).not_to include("Other Payer")
    end
  end

  describe "GET /receipts/:id" do
    let!(:receipt) do
      res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 120_000,
        received_on: Date.new(2026, 1, 10),
        payment_method: "zelle",
        external_reference: "ZEL123",
        memo: "January Rent"
      )
      res.value!.data[:receipt]
    end

    it "renders HTML details" do
      get receipt_url(receipt)
      expect(response).to be_successful
      expect(response.body).to include("Receipt from Alice Walker")
      expect(response.body).to include("$1,200.00")
      expect(response.body).to include("Alice Walker")
      expect(response.body).to include("ZEL123")
    end

    it "renders PDF receipt" do
      get receipt_url(receipt, format: :pdf)
      expect(response).to be_successful
      expect(response.content_type).to eq("application/pdf")
      expect(response.body).to start_with("%PDF-")
    end

    it "returns 404 for other user's receipt" do
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_payer = create(:party, user: other_user)
      other_receipt = create(:receipt, user: other_user, tenancy: other_tenancy, payer_party: other_payer)

      get receipt_url(other_receipt)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /receipts/new and GET /tenancies/:id/receipts/new" do
    it "renders top-level new receipt page" do
      get new_receipt_url
      expect(response).to be_successful
      expect(response.body).to include("Record receipt")
    end

    it "renders nested new receipt page preselecting single active tenant" do
      get new_tenancy_receipt_url(tenancy)
      expect(response).to be_successful
      expect(response.body).to include("Alice Walker")
      expect(response.body).to include(tenancy.property.address)
    end

    it "renders nested new receipt form with constant queries regardless of participant count" do
      get new_tenancy_receipt_url(tenancy)

      queries = []
      counter = ->(_name, _started, _finished, _unique_id, data) {
        queries << data[:sql] unless data[:name].in?(%w[SCHEMA CACHE]) || data[:sql].match?(/\A\s*(SAVEPOINT|ROLLBACK|COMMIT|BEGIN)/i)
      }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get new_tenancy_receipt_url(tenancy)
      end
      baseline_count = queries.size

      5.times do |i|
        p = create(:party, user: user, display_name: "Co-tenant #{i}")
        create(:tenancy_party, tenancy: tenancy, party: p, role: "tenant", effective_from: tenancy.commencement_date)
      end

      queries = []
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get new_tenancy_receipt_url(tenancy)
      end
      expect(queries.size).to eq(baseline_count)
      expect(response).to be_successful
    end
  end

  describe "POST /receipts and POST /tenancies/:id/receipts" do
    it "creates receipt via top-level route" do
      expect {
        post receipts_url, params: {
          receipt: {
            tenancy_id: tenancy.id,
            payer_party_id: party.id,
            amount: "1500.00",
            received_on: "2026-02-01",
            payment_method: "check",
            external_reference: "CHK99",
            memo: "Feb Rent"
          }
        }
      }.to change(Receipt, :count).by(1)
       .and change(JournalEntry, :count).by(1)

      created = Receipt.last
      expect(response).to redirect_to(receipt_path(created))
      expect(flash[:notice]).to eq("Payment recorded successfully.")
      expect(created.amount_cents).to eq(150_000)
    end

    it "creates receipt via top-level route with turbo_stream format redirecting to receipt show" do
      expect {
        post receipts_url, params: {
          receipt: {
            tenancy_id: tenancy.id,
            payer_party_id: party.id,
            amount: "1500.00",
            received_on: "2026-02-01",
            payment_method: "check"
          }
        }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      }.to change(Receipt, :count).by(1)

      created = Receipt.last
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(receipt_path(created))
    end

    it "renders 422 for top-level creation with missing tenancy_id" do
      post receipts_url, params: {
        receipt: {
          payer_party_id: party.id,
          amount: "1500.00",
          received_on: "2026-02-01",
          payment_method: "check"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('aria-describedby="receipt-tenancy-error"')
      expect(response.body).to include('id="receipt-tenancy-error"')

      post receipts_url, params: {
        receipt: {
          payer_party_id: party.id,
          amount: "1500.00",
          received_on: "2026-02-01",
          payment_method: "check"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "renders 422 for top-level creation with unknown tenancy_id" do
      post receipts_url, params: {
        receipt: {
          tenancy_id: 999_999,
          payer_party_id: party.id,
          amount: "1500.00",
          received_on: "2026-02-01",
          payment_method: "check"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)

      post receipts_url, params: {
        receipt: {
          tenancy_id: 999_999,
          payer_party_id: party.id,
          amount: "1500.00",
          received_on: "2026-02-01",
          payment_method: "check"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "renders 422 for top-level creation with unknown payer_party_id" do
      post receipts_url, params: {
        receipt: {
          tenancy_id: tenancy.id,
          payer_party_id: 999_999,
          amount: "1500.00",
          received_on: "2026-02-01",
          payment_method: "check"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('aria-describedby="receipt-payer-error"')
      expect(response.body).to include('id="receipt-payer-error"')

      post receipts_url, params: {
        receipt: {
          tenancy_id: tenancy.id,
          payer_party_id: 999_999,
          amount: "1500.00",
          received_on: "2026-02-01",
          payment_method: "check"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "renders field error and ARIA attributes when external reference is duplicate" do
      create(:receipt, tenancy: tenancy, payer_party: party, user: user, external_reference: "REF-12345")
      post tenancy_receipts_path(tenancy, format: :html), params: {
        receipt: {
          payer_party_id: party.id,
          amount: "500.00",
          received_on: "2026-02-01",
          payment_method: "check",
          external_reference: "REF-12345"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('aria-describedby="receipt-ref-error"')
      expect(response.body).to include('id="receipt-ref-error"')
    end

    it "renders 422 for top-level creation when service fails and maps field errors" do
      post receipts_url, params: {
        receipt: {
          tenancy_id: tenancy.id,
          payer_party_id: party.id,
          amount: "-50.00",
          received_on: "2026-02-01",
          payment_method: "check"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)

      allow(Receipts::CreateService).to receive(:call).and_return(
        ServiceResult.failure(error: "Payer party is required", code: :validation_error)
      )
      post receipts_url, params: {
        receipt: { tenancy_id: tenancy.id, amount: "50.00", payment_method: "check" }
      }
      expect(response).to have_http_status(:unprocessable_content)

      allow(Receipts::CreateService).to receive(:call).and_return(
        ServiceResult.failure(error: "Received on date is invalid", code: :validation_error)
      )
      post receipts_url, params: {
        receipt: { tenancy_id: tenancy.id, amount: "50.00", payment_method: "check" }
      }
      expect(response).to have_http_status(:unprocessable_content)

      allow(Receipts::CreateService).to receive(:call).and_return(
        ServiceResult.failure(error: "Payment method is required", code: :validation_error)
      )
      post receipts_url, params: {
        receipt: { tenancy_id: tenancy.id, amount: "50.00" }
      }
      expect(response).to have_http_status(:unprocessable_content)

      allow(Receipts::CreateService).to receive(:call).and_return(
        ServiceResult.failure(error: "Internal error", code: :validation_error)
      )
      post receipts_url, params: {
        receipt: { tenancy_id: tenancy.id, amount: "50.00" }
      }
      expect(response).to have_http_status(:unprocessable_content)

      post receipts_url, params: {
        receipt: {
          tenancy_id: tenancy.id,
          payer_party_id: party.id,
          amount: "-50.00",
          received_on: "2026-02-01",
          payment_method: "check"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "creates receipt via nested tenancy route" do
      expect {
        post tenancy_receipts_url(tenancy), params: {
          receipt: {
            payer_party_id: party.id,
            amount: "1200.00",
            received_on: "2026-02-01",
            payment_method: "zelle"
          }
        }
      }.to change(Receipt, :count).by(1)

      expect(response).to redirect_to(tenancy_path(tenancy))
    end

    it "rejects nested creation with mismatched tenancy_id in body" do
      other_unit = create(:rentable_unit, property: property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)

      expect {
        post tenancy_receipts_url(tenancy), params: {
          receipt: {
            tenancy_id: other_tenancy.id,
            payer_party_id: party.id,
            amount: "1200.00",
            received_on: "2026-02-01",
            payment_method: "zelle"
          }
        }
      }.not_to change(Receipt, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Submitted tenancy does not match route tenancy")
    end

    it "returns 404 and creates no receipt when nested route tenancy does not exist" do
      expect {
        post "/tenancies/999999/receipts", params: {
          receipt: {
            tenancy_id: tenancy.id,
            payer_party_id: party.id,
            amount: "1200.00",
            received_on: "2026-02-01",
            payment_method: "zelle"
          }
        }
      }.not_to change(Receipt, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 and creates no receipt when nested route tenancy belongs to another user" do
      other_prop = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_prop)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)

      expect {
        post tenancy_receipts_url(other_tenancy), params: {
          receipt: {
            tenancy_id: tenancy.id,
            payer_party_id: party.id,
            amount: "1200.00",
            received_on: "2026-02-01",
            payment_method: "zelle"
          }
        }
      }.not_to change(Receipt, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "creates receipt via format: :html, returns 303 see_other, and redirects to tenancy Activity" do
      expect {
        post tenancy_receipts_url(tenancy, format: :html), params: {
          receipt: {
            payer_party_id: party.id,
            amount: "1200.00",
            received_on: "2026-02-01",
            payment_method: "zelle"
          }
        }
      }.to change(Receipt, :count).by(1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(tenancy_path(tenancy))
      expect(flash[:notice]).to eq("Payment recorded successfully.")
    end

    it "renders 422 unprocessable_content on invalid standalone format: :html submission and preserves .html action URL" do
      expect {
        post tenancy_receipts_url(tenancy, format: :html), params: {
          receipt: {
            payer_party_id: party.id,
            amount: "-50.00",
            received_on: "2026-02-01",
            payment_method: "zelle"
          }
        }
      }.not_to change(Receipt, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include("Record receipt")
      expect(response.body).to match(/action="[^"]*tenancies\/#{tenancy.id}\/receipts(\.html|\?format=html)"/)
    end

    it "creates receipt via turbo_stream format" do
      post tenancy_receipts_url(tenancy), params: {
        receipt: {
          payer_party_id: party.id,
          amount: "1200.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("close_modal")
      expect(response.body).to include("tenancy_balance")
      expect(response.body).to include("tenancy_activity")
      expect(response.body).to include("target=\"tenancy_delete_action\"")
      expect(response.body).not_to include("target=\"tenancy_actions\"")
      expect(response.body).to include("target=\"flash-messages\"")
      expect(response.body).to include("Payment recorded successfully.")
    end

    it "creates receipt via turbo_stream format on past tenancy with partial payment and preserves tenancy_actions" do
      past_unit = create(:rentable_unit, property: property, name: "Past Stream Unit Partial")
      past_tenancy = create(:tenancy, rentable_unit: past_unit, commencement_date: Date.current - 1.year, termination_date: Date.current - 1.month)
      past_party = create(:party, user: user, display_name: "Past Payer 1")
      create(:tenancy_party, tenancy: past_tenancy, party: past_party, role: "tenant", effective_from: past_tenancy.commencement_date)
      Charges::CreateFeeService.call(tenancy: past_tenancy, charge_kind: "other", amount_cents: 40_000, charge_date: past_tenancy.termination_date, due_on: past_tenancy.termination_date)

      post tenancy_receipts_url(past_tenancy), params: {
        receipt: {
          payer_party_id: past_party.id,
          amount: "100.00",
          received_on: Date.current.to_s,
          payment_method: "zelle"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("target=\"tenancy_delete_action\"")
      expect(response.body).not_to include("target=\"tenancy_actions\"")
    end

    it "creates receipt via turbo_stream format on past tenancy with full payoff and refreshes tenancy_actions" do
      past_unit = create(:rentable_unit, property: property, name: "Past Stream Unit Full")
      past_tenancy = create(:tenancy, rentable_unit: past_unit, commencement_date: Date.current - 1.year, termination_date: Date.current - 1.month)
      past_party = create(:party, user: user, display_name: "Past Payer 2")
      create(:tenancy_party, tenancy: past_tenancy, party: past_party, role: "tenant", effective_from: past_tenancy.commencement_date)
      Charges::CreateFeeService.call(tenancy: past_tenancy, charge_kind: "other", amount_cents: 40_000, charge_date: past_tenancy.termination_date, due_on: past_tenancy.termination_date)

      post tenancy_receipts_url(past_tenancy), params: {
        receipt: {
          payer_party_id: past_party.id,
          amount: "400.00",
          received_on: Date.current.to_s,
          payment_method: "zelle"
        }
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("target=\"tenancy_actions\"")
    end

    it "rejects top-level creation with blank tenancy_id" do
      post receipts_url, params: {
        receipt: {
          tenancy_id: "",
          payer_party_id: party.id,
          amount: "1200.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tenancy is required")
    end

    it "rejects top-level creation with invalid or foreign tenancy_id while preserving valid payer" do
      other_prop = create(:property, user: other_user)
      other_t = create(:tenancy, rentable_unit: create(:rentable_unit, property: other_prop))

      # Foreign tenancy preserves valid payer
      post receipts_url, params: {
        receipt: {
          tenancy_id: other_t.id,
          payer_party_id: party.id,
          amount: "1200.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to eq("Tenancy was not found")
      expect(response.body).to include("selected=\"selected\" value=\"#{party.id}\"")
      expect(response.body).not_to include("must belong to the receipt owner")

      # Nonexistent tenancy preserves valid payer
      post receipts_url, params: {
        receipt: {
          tenancy_id: 999_999,
          payer_party_id: party.id,
          amount: "1200.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to eq("Tenancy was not found")
      expect(response.body).to include("selected=\"selected\" value=\"#{party.id}\"")

      # Blank tenancy preserves valid payer
      post receipts_url, params: {
        receipt: {
          tenancy_id: "",
          payer_party_id: party.id,
          amount: "1200.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to eq("Tenancy is required")
      expect(response.body).to include("selected=\"selected\" value=\"#{party.id}\"")
    end

    it "rejects creation with invalid or foreign payer_party_id without leaking existence" do
      other_p = create(:party, user: other_user)

      post receipts_url, params: {
        receipt: {
          tenancy_id: tenancy.id,
          payer_party_id: other_p.id,
          amount: "1200.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to eq("Payer party was not found")
      expect(response.body).not_to include("selected=\"selected\" value=\"#{other_p.id}\"")
      expect(response.body).not_to include("must belong to the receipt owner")
    end

    it "handles new receipt form when tenancy has no active tenants or multiple active tenants" do
      unit2 = create(:rentable_unit, property: property, name: "Unit 2")
      tenancy_no_tenants = create(:tenancy, rentable_unit: unit2)
      get new_tenancy_receipt_url(tenancy_no_tenants)
      expect(response).to be_successful

      party2 = create(:party, user: user, display_name: "Bob Builder")
      create(:tenancy_party, tenancy: tenancy, party: party2, role: "tenant")
      get new_tenancy_receipt_url(tenancy)
      expect(response).to be_successful
    end

    it "renders turbo_stream form on error" do
      post tenancy_receipts_url(tenancy, format: :turbo_stream), params: {
        receipt: {
          payer_party_id: party.id,
          amount: "-50.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include("action=\"update\" target=\"modal-frame\"")
    end

    it "renders unprocessable_content on invalid parameters" do
      expect {
        post receipts_url, params: {
          receipt: {
            tenancy_id: tenancy.id,
            payer_party_id: party.id,
            amount: "0",
            received_on: "2026-02-01",
            payment_method: "zelle"
          }
        }
      }.not_to change(Receipt, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Amount must be greater than 0")
    end

    it "rejects create with unresolvable or foreign payer_party_id" do
      other_user_party = create(:party, user: other_user)
      post receipts_url, params: {
        receipt: {
          tenancy_id: tenancy.id,
          payer_party_id: other_user_party.id,
          amount: "100.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Payer party was not found")
    end

    it "rejects create with missing tenancy_id" do
      post receipts_url, params: {
        receipt: {
          tenancy_id: "",
          payer_party_id: party.id,
          amount: "100.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tenancy is required")
    end

    it "rejects create with unresolvable tenancy_id" do
      post receipts_url, params: {
        receipt: {
          tenancy_id: 999_999,
          payer_party_id: party.id,
          amount: "100.00",
          received_on: "2026-02-01",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tenancy was not found")
    end
  end

  describe "GET /receipts/:id/correction and POST /receipts/:id/correct" do
    let!(:receipt) do
      res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 200_000,
        received_on: Date.new(2026, 1, 10),
        payment_method: "zelle",
        external_reference: "ZEL100"
      )
      res.value!.data[:receipt]
    end

    it "renders the correction form" do
      get correction_receipt_url(receipt)
      expect(response).to be_successful
      expect(response.body).to include("Correct receipt")
      expect(response.body).to include("ZEL100")
    end

    it "submits a correction and replaces the receipt" do
      expect {
        post correct_receipt_url(receipt), params: {
          receipt: {
            amount: "2100.00",
            received_on: "2026-01-10",
            payment_method: "zelle",
            external_reference: "ZEL100"
          }
        }
      }.to change(Receipt, :count).by(1)

      replacement = Receipt.last
      expect(response).to redirect_to(receipt_path(replacement))
      expect(flash[:notice]).to include("Payment corrected successfully")
      expect(receipt.reload.voided?).to be true
      expect(receipt.superseded_by).to eq(replacement)
    end

    it "is idempotent on repeated identical correction POST submissions" do
      # First submission
      post correct_receipt_url(receipt), params: {
        receipt: {
          amount: "2100.00",
          received_on: "2026-01-10",
          payment_method: "zelle",
          external_reference: "ZEL100"
        }
      }
      replacement = Receipt.last
      expect(response).to redirect_to(receipt_path(replacement))

      # Second identical submission (e.g. user double-clicked or refreshed)
      expect {
        post correct_receipt_url(receipt), params: {
          receipt: {
            amount: "2100.00",
            received_on: "2026-01-10",
            payment_method: "zelle",
            external_reference: "ZEL100"
          }
        }
      }.not_to change(Receipt, :count)

      expect(response).to redirect_to(receipt_path(replacement))
    end

    it "rejects correction with unresolvable or foreign payer_party_id without leaking ownership mismatch" do
      other_user_party = create(:party, user: other_user)
      post correct_receipt_url(receipt), params: {
        receipt: {
          payer_party_id: other_user_party.id,
          amount: "2100.00"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Payer party was not found")
      expect(response.body).not_to include("must belong to the receipt owner")
      expect(response.body).not_to include("must exist")

      post correct_receipt_url(receipt), params: {
        receipt: {
          payer_party_id: 999_999,
          amount: "2100.00"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Payer party was not found")
      expect(response.body).not_to include("must belong to the receipt owner")
      expect(response.body).not_to include("must exist")
    end

    it "rejects correction with unresolvable or foreign tenancy_id without leaking ownership mismatch" do
      other_tenancy = create(:tenancy)
      post correct_receipt_url(receipt), params: {
        receipt: {
          tenancy_id: other_tenancy.id,
          amount: "2100.00"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tenancy was not found")
      expect(response.body).not_to include("must belong to the receipt owner")
      expect(response.body).not_to include("must exist")

      post correct_receipt_url(receipt), params: {
        receipt: {
          tenancy_id: 999_999,
          amount: "2100.00"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tenancy was not found")
      expect(response.body).not_to include("must belong to the receipt owner")
      expect(response.body).not_to include("must exist")
    end

    it "renders unprocessable_content on invalid correction" do
      post correct_receipt_url(receipt), params: {
        receipt: {
          amount: "-100.00",
          received_on: "2026-01-10",
          payment_method: "zelle",
          memo: "Updated memo note"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Amount must be greater than 0")
      expect(response.body).to include('aria-describedby="receipt-correct-amount-error"')
      expect(response.body).to include('id="receipt-correct-amount-error"')
      expect(response.body).to include('Updated memo note')
    end

    it "preserves unparsable and scientific-notation submitted amount on correction failure" do
      post correct_receipt_url(receipt), params: {
        receipt: {
          amount: "invalid_sum",
          received_on: "2026-01-10",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('value="invalid_sum"')
      expect(response.body).to include('id="receipt-correct-amount-error"')

      post correct_receipt_url(receipt), params: {
        receipt: {
          amount: "1e3",
          received_on: "2026-01-10",
          payment_method: "zelle"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('value="1e3"')
      expect(response.body).not_to include('value="1000.00"')
    end

    it "rejects correction with blank required fields instead of silently using originals" do
      expect {
        post correct_receipt_url(receipt), params: {
          receipt: {
            tenancy_id: "",
            payer_party_id: "",
            amount: "",
            received_on: "",
            payment_method: ""
          }
        }
      }.not_to change(Receipt, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('id="receipt-correct-tenancy-error"')
      expect(response.body).to include('id="receipt-correct-payer-error"')
      expect(response.body).to include('id="receipt-correct-amount-error"')
      expect(response.body).to include('id="receipt-correct-date-error"')
      expect(response.body).to include('id="receipt-correct-method-error"')
    end

    it "maps service failure messages to specific receipt correction field errors" do
      allow(Receipts::CorrectService).to receive(:call).and_return(
        ServiceResult.failure(error: "Payment method is invalid", code: :validation_error)
      )
      post correct_receipt_url(receipt), params: {
        receipt: { amount: "100.00", received_on: "2026-01-10", payment_method: "zelle" }
      }
      expect(response.body).to include('id="receipt-correct-method-error"')

      allow(Receipts::CorrectService).to receive(:call).and_return(
        ServiceResult.failure(error: "Received on date is invalid", code: :validation_error)
      )
      post correct_receipt_url(receipt), params: {
        receipt: { amount: "100.00", received_on: "2026-01-10", payment_method: "zelle" }
      }
      expect(response.body).to include('id="receipt-correct-date-error"')

      allow(Receipts::CorrectService).to receive(:call).and_return(
        ServiceResult.failure(error: "External reference is duplicate", code: :validation_error)
      )
      post correct_receipt_url(receipt), params: {
        receipt: { amount: "100.00", received_on: "2026-01-10", payment_method: "zelle" }
      }
      expect(response.body).to include('id="receipt-correct-ref-error"')

      allow(Receipts::CorrectService).to receive(:call).and_return(
        ServiceResult.failure(error: "Tenancy is invalid", code: :validation_error)
      )
      post correct_receipt_url(receipt), params: {
        receipt: { amount: "100.00", received_on: "2026-01-10", payment_method: "zelle" }
      }
      expect(response.body).to include('id="receipt-correct-tenancy-error"')

      allow(Receipts::CorrectService).to receive(:call).and_return(
        ServiceResult.failure(error: "Payer party is invalid", code: :validation_error)
      )
      post correct_receipt_url(receipt), params: {
        receipt: { amount: "100.00", received_on: "2026-01-10", payment_method: "zelle" }
      }
      expect(response.body).to include('id="receipt-correct-payer-error"')

      allow(Receipts::CorrectService).to receive(:call).and_return(
        ServiceResult.failure(error: "Generic unexpected error", code: :validation_error)
      )
      post correct_receipt_url(receipt), params: {
        receipt: { amount: "100.00", received_on: "2026-01-10", payment_method: "zelle" }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /receipts/:id/void" do
    let!(:receipt) do
      res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 100_000,
        received_on: Date.new(2026, 1, 10),
        payment_method: "zelle"
      )
      res.value!.data[:receipt]
    end

    it "voids the receipt" do
      post void_receipt_url(receipt), params: { reason: "Mistaken entry" }
      expect(response).to redirect_to(receipt_path(receipt))
      expect(flash[:notice]).to include("Payment has been voided")
      expect(receipt.reload.voided?).to be true
    end

    it "handles void failure gracefully" do
      allow(Receipts::VoidService).to receive(:call).and_return(
        ServiceResult.failure(error: "Cannot void locked receipt", code: :void_failed)
      )
      post void_receipt_url(receipt)
      expect(response).to redirect_to(receipt_path(receipt))
      expect(flash[:alert]).to eq("Cannot void locked receipt")
    end
  end
end
