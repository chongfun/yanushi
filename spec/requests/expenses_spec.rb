require "rails_helper"

RSpec.describe "Expenses", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:other_property) { create(:property, user: other_user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:other_unit) { create(:rentable_unit, property: other_property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let!(:expense) do
    res = Expenses::CreateService.call(
      property: property,
      expense_kind: "repairs",
      amount_cents: 10_000,
      paid_on: Date.today
    )
    res.value!.data[:expense]
  end

  before do
    sign_in_as(user)
  end

  describe "GET /index" do
    it "renders a successful response" do
      get expenses_url
      expect(response).to be_successful
    end
  end

  describe "GET /new" do
    it "renders a successful response and filters out other user data" do
      get new_expense_url
      expect(response).to be_successful
      expect(response.body).not_to include(other_property.address)
    end

    it "sets property when property_id is passed in nested route" do
      get new_property_expense_url(property)
      expect(response).to be_successful
      expect(response.body).to include(property.address)
      expect(response.body).to match(/action="[^"]*properties\/#{property.id}\/expenses(\.html|\?format=html)"/)
    end
  end

  describe "POST /create" do
    it "creates an expense with valid parameters" do
      expect {
        post expenses_url, params: {
          expense: {
            amount: "100.00",
            expense_kind: "repairs",
            description: "Faucet repair",
            paid_on: Date.today,
            property_id: property.id
          }
        }
      }.to change(Expense, :count).by(1)
       .and change(JournalEntry, :count).by(1)

      expect(response).to redirect_to(expense_url(Expense.last))
    end

    it "ignores submitted amount_cents parameter and creates with amount" do
      expect {
        post expenses_url, params: {
          expense: {
            amount: "100.00",
            amount_cents: 1,
            expense_kind: "repairs",
            description: "Faucet repair",
            paid_on: Date.today,
            property_id: property.id
          }
        }
      }.to change(Expense, :count).by(1)

      expense = Expense.last
      expect(expense.amount_cents).to eq(10_000)
      expect(expense.amount).to eq(100.00)
    end

    it "fails to create an expense when property_id is blank and renders full HTML with ARIA error associations" do
      expect {
        post expenses_url(format: :html), params: {
          expense: {
            amount: "100.00",
            expense_kind: "repairs",
            description: "Faucet",
            paid_on: Date.today,
            property_id: ""
          }
        }
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include('aria-describedby="expense-property-error"')
      expect(response.body).to include('id="expense-property-error"')
    end

    it "renders field-level ARIA error attributes for amount and category on validation failure" do
      post expenses_url(format: :html), params: {
        expense: {
          amount: "-50.00",
          expense_kind: "repairs",
          description: "Faucet",
          paid_on: Date.today,
          property_id: property.id
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include('aria-describedby="expense-amount-error"')
      expect(response.body).to include('id="expense-amount-error"')

      post expenses_url(format: :html), params: {
        expense: {
          amount: "50.00",
          expense_kind: "",
          description: "Faucet",
          paid_on: Date.today,
          property_id: property.id
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include('aria-describedby="expense-kind-error"')
      expect(response.body).to include('id="expense-kind-error"')
    end

    it "preserves blank amount and blank date on validation failure without defaulting" do
      post expenses_url(format: :html), params: {
        expense: {
          amount: "",
          expense_kind: "repairs",
          description: "Faucet",
          paid_on: "",
          property_id: property.id
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('id="expense-amount-error"')
      expect(response.body).to include('id="expense-date-error"')
      # Value attributes should not contain 0.00 or today's date
      expect(response.body).not_to include('id="expense-amount" placeholder="0.00" required="required" value="0.00"')
      expect(response.body).not_to include("value=\"#{Date.current}\"")
    end

    it "creates nested expense and redirects to property activity path" do
      expect {
        post property_expenses_url(property), params: {
          expense: {
            amount: "100.00",
            expense_kind: "repairs",
            description: "Faucet",
            paid_on: Date.today
          }
        }
      }.to change(Expense, :count).by(1)

      expect(response).to redirect_to(property_activity_path(property))
    end

    it "creates nested expense via Turbo Stream and updates property summary/activity" do
      expect {
        post property_expenses_url(property, format: :turbo_stream), params: {
          expense: {
            amount: "100.00",
            expense_kind: "repairs",
            description: "Faucet",
            paid_on: Date.today
          }
        }
      }.to change(Expense, :count).by(1)

      expect(response).to be_successful
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('action="close_modal"')
      expect(response.body).to include('target="property_summary"')
      expect(response.body).to include('target="property_recent_activity"')
    end

    it "handles nested expense validation failure in dialog variant with turbo_stream" do
      expect {
        post property_expenses_url(property), params: {
          expense: {
            amount: "-50.0",
            expense_kind: "repairs",
            description: "Faucet",
            paid_on: Date.today
          }
        }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('action="update" target="modal-frame"')
      expect(response.body).to include('id="expense-amount-error"')
    end

    it "handles nested expense validation failure in standalone variant with text/html" do
      expect {
        post property_expenses_url(property, format: :html), params: {
          expense: {
            amount: "-50.0",
            expense_kind: "repairs",
            description: "Faucet",
            paid_on: Date.today
          }
        }
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include('aria-describedby="expense-amount-error"')
      expect(response.body).to include('id="expense-amount-error"')
    end

    it "should not create expense with other user's property" do
      expect {
        post expenses_url, params: {
          expense: {
            amount: "100.00",
            expense_kind: "repairs",
            paid_on: Date.today,
            property_id: other_property.id
          }
        }
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "does not disclose foreign property rentable units on 422 create response (P1 isolation)" do
      foreign_unit = create(:rentable_unit, property: other_property, name: "Secret Penthouse 9999")
      expect {
        post expenses_url, params: {
          expense: {
            amount: "100.00",
            expense_kind: "repairs",
            paid_on: Date.today,
            property_id: other_property.id
          }
        }
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include("Secret Penthouse 9999")
      expect(response.body).not_to include("value=\"#{foreign_unit.id}\"")
    end

    it "preserves malformed and scientific-notation amount input on 422 create without raising ArgumentError" do
      post expenses_url, params: {
        expense: {
          property_id: property.id,
          expense_kind: "repairs",
          amount: "garbage",
          paid_on: Date.today
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('value="garbage"')
      expect(response.body).to include('id="expense-amount-error"')

      post expenses_url, params: {
        expense: {
          property_id: property.id,
          expense_kind: "repairs",
          amount: "1e3",
          paid_on: Date.today
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('value="1e3"')
      expect(response.body).not_to include('value="1000.00"')
    end

    it "rejects nested route with mismatched property_id" do
      post property_expenses_url(property), params: {
        expense: {
          amount: "100.00",
          expense_kind: "repairs",
          paid_on: Date.today,
          property_id: other_property.id
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects rentable_unit from wrong property" do
      post expenses_url, params: {
        expense: {
          amount: "100.00",
          expense_kind: "repairs",
          paid_on: Date.today,
          property_id: property.id,
          rentable_unit_id: other_unit.id
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "maps service failure messages to specific field errors" do
      err_struct = Struct.new(:error, :data)
      allow(Expenses::CreateService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Paid date cannot be in future", {}))
      )
      post expenses_url(format: :html), params: {
        expense: { amount: "100.00", expense_kind: "repairs", paid_on: Date.today, property_id: property.id }
      }
      expect(response.body).to include('id="expense-date-error"')

      allow(Expenses::CreateService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Vendor name is invalid", {}))
      )
      post expenses_url(format: :html), params: {
        expense: { amount: "100.00", expense_kind: "repairs", paid_on: Date.today, property_id: property.id }
      }
      expect(response.body).to include('id="expense-vendor-error"')

      allow(Expenses::CreateService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("External reference is duplicate", {}))
      )
      post expenses_url(format: :html), params: {
        expense: { amount: "100.00", expense_kind: "repairs", paid_on: Date.today, property_id: property.id }
      }
      expect(response.body).to include('id="expense-ref-error"')

      allow(Expenses::CreateService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Generic ledger error", {}))
      )
      post expenses_url(format: :html), params: {
        expense: { amount: "100.00", expense_kind: "repairs", paid_on: Date.today, property_id: property.id }
      }
      expect(response).to have_http_status(:unprocessable_content)

      # JSON format
      post expenses_url, params: {
        expense: { amount: "100.00", expense_kind: "repairs", paid_on: Date.today, property_id: property.id }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "creates expense and returns JSON" do
      post expenses_url, params: {
        expense: {
          amount: "100.00",
          expense_kind: "repairs",
          paid_on: Date.today,
          property_id: property.id
        }
      }, as: :json
      expect(response).to have_http_status(:created)
    end

    it "returns JSON errors on validation failure" do
      post expenses_url, params: {
        expense: {
          amount: "-50.0",
          expense_kind: "repairs",
          paid_on: Date.today,
          property_id: property.id
        }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "redirects to nested property activity on non-turbo success" do
      post property_expenses_url(property), params: {
        expense: {
          amount: "100.00",
          expense_kind: "repairs",
          paid_on: Date.today
        }
      }
      expect(response).to redirect_to(property_activity_path(property))
    end
  end

  describe "GET /show" do
    it "renders a successful response" do
      get expense_url(expense)
      expect(response).to be_successful
    end
  end

  describe "GET /expenses/:id/correction" do
    it "renders the correction form for active expense" do
      get correction_expense_url(expense)
      expect(response).to be_successful
    end

    it "renders correction form and notice when expense has active reimbursement charges" do
      Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy,
        amount_cents: 5_000
      )

      get correction_expense_url(expense)
      expect(response).to be_successful
      expect(response.body).to include("Active Reimbursements Notice")
    end

    it "redirects if expense is voided" do
      Expenses::VoidService.call(expense: expense)

      get correction_expense_url(expense)
      expect(response).to redirect_to(expense_url(expense))
      expect(flash[:alert]).to include("already been corrected or voided")
    end
  end

  describe "POST /expenses/:id/correct" do
    it "corrects the expense, reversing original and creating replacement" do
      expect {
        post correct_expense_url(expense), params: {
          expense: {
            property_id: property.id,
            expense_kind: "utilities",
            amount: "150.00",
            paid_on: Date.today,
            vendor_name: "Power Co"
          }
        }
      }.to change(Expense, :count).by(1)
       .and change(JournalEntry, :count).by(2)

      replacement = Expense.last
      expect(response).to redirect_to(expense_url(replacement))
      expect(expense.reload).to be_voided
      expect(expense.superseded_by).to eq(replacement)
    end

    it "successfully corrects expense and restates active reimbursements" do
      reimb_res = Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy,
        amount_cents: 5_000
      )
      orig_charge = reimb_res.value!.data[:charge]

      post correct_expense_url(expense), params: {
        expense: {
          property_id: property.id,
          expense_kind: "utilities",
          amount: "150.00",
          paid_on: Date.today
        }
      }
      replacement = Expense.last
      expect(response).to redirect_to(expense_url(replacement))
      expect(orig_charge.reload).to be_superseded
      expect(orig_charge.superseded_by.source_expense_id).to eq(replacement.id)
    end

    it "rejects correction if expense is already voided" do
      Expenses::VoidService.call(expense: expense)

      post correct_expense_url(expense), params: {
        expense: {
          property_id: property.id,
          expense_kind: "utilities",
          amount: "150.00",
          paid_on: Date.today
        }
      }
      expect(response).to redirect_to(expense_url(expense))
      expect(flash[:alert]).to include("already been corrected or voided")
    end

    it "rejects correction if expense is already superseded" do
      Expenses::CorrectService.call(expense: expense, amount_cents: 15_000)

      post correct_expense_url(expense), params: {
        expense: {
          property_id: property.id,
          expense_kind: "utilities",
          amount: "200.00",
          paid_on: Date.today
        }
      }
      expect(response).to redirect_to(expense_url(expense))
      expect(flash[:alert]).to include("already been corrected or voided")
    end

    it "rejects correction with unit from wrong property" do
      post correct_expense_url(expense), params: {
        expense: {
          property_id: property.id,
          rentable_unit_id: other_unit.id,
          expense_kind: "utilities",
          amount: "150.00",
          paid_on: Date.today
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects correction with property belonging to another user" do
      post correct_expense_url(expense), params: {
        expense: {
          property_id: other_property.id,
          expense_kind: "utilities",
          amount: "150.00",
          paid_on: Date.today
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "does not disclose foreign property rentable units on 422 correction response (P1 isolation)" do
      foreign_unit = create(:rentable_unit, property: other_property, name: "Secret Penthouse 9999")
      post correct_expense_url(expense), params: {
        expense: {
          property_id: other_property.id,
          expense_kind: "utilities",
          amount: "150.00",
          paid_on: Date.today
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include("Secret Penthouse 9999")
      expect(response.body).not_to include("value=\"#{foreign_unit.id}\"")
    end

    it "preserves malformed and scientific-notation amount input on 422 correction without raising ArgumentError" do
      post correct_expense_url(expense), params: {
        expense: {
          property_id: property.id,
          expense_kind: "repairs",
          amount: "garbage",
          paid_on: Date.today
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('value="garbage"')
      expect(response.body).to include('id="expense-correct-amount-error"')

      post correct_expense_url(expense), params: {
        expense: {
          property_id: property.id,
          expense_kind: "repairs",
          amount: "1e3",
          paid_on: Date.today
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('value="1e3"')
      expect(response.body).not_to include('value="1000.00"')
    end

    it "rejects correction with blank required fields instead of silently using originals" do
      expect {
        post correct_expense_url(expense), params: {
          expense: {
            property_id: property.id,
            expense_kind: "",
            amount: "",
            paid_on: ""
          }
        }
      }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('id="expense-correct-kind-error"')
      expect(response.body).to include('id="expense-correct-amount-error"')
      expect(response.body).to include('id="expense-correct-date-error"')
    end

    it "renders correction with unprocessable_content and ARIA attributes when service fails, preserving submitted input" do
      post correct_expense_url(expense), params: {
        expense: {
          property_id: property.id,
          expense_kind: "utilities",
          amount: "-100.00",
          paid_on: Date.today,
          vendor_name: "Custom Utility Co",
          external_reference: "REF-CORRECT-1",
          description: "Updated notes"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('aria-describedby="expense-correct-amount-error"')
      expect(response.body).to include('id="expense-correct-amount-error"')
      expect(response.body).to include('value="Custom Utility Co"')
      expect(response.body).to include('value="REF-CORRECT-1"')
      expect(response.body).to include('Updated notes')
    end

    it "maps service failure messages to specific correction field errors" do
      err_struct = Struct.new(:error, :data)
      allow(Expenses::CorrectService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Category is required", {}))
      )
      post correct_expense_url(expense), params: {
        expense: { property_id: property.id, expense_kind: "repairs", paid_on: Date.today, amount: "50.00" }
      }
      expect(response.body).to include('id="expense-correct-kind-error"')

      allow(Expenses::CorrectService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Paid date cannot be in future", {}))
      )
      post correct_expense_url(expense), params: {
        expense: { property_id: property.id, expense_kind: "repairs", paid_on: Date.today, amount: "50.00" }
      }
      expect(response.body).to include('id="expense-correct-date-error"')

      allow(Expenses::CorrectService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Vendor name is invalid", {}))
      )
      post correct_expense_url(expense), params: {
        expense: { property_id: property.id, expense_kind: "repairs", paid_on: Date.today, amount: "50.00" }
      }
      expect(response.body).to include('id="expense-correct-vendor-error"')

      allow(Expenses::CorrectService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Reference is duplicate", {}))
      )
      post correct_expense_url(expense), params: {
        expense: { property_id: property.id, expense_kind: "repairs", paid_on: Date.today, amount: "50.00" }
      }
      expect(response.body).to include('id="expense-correct-ref-error"')

      allow(Expenses::CorrectService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Property is invalid", {}))
      )
      post correct_expense_url(expense), params: {
        expense: { property_id: property.id, expense_kind: "repairs", paid_on: Date.today, amount: "50.00" }
      }
      expect(response.body).to include('id="expense-correct-property-error"')

      allow(Expenses::CorrectService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Unit is invalid", {}))
      )
      post correct_expense_url(expense), params: {
        expense: { property_id: property.id, expense_kind: "repairs", paid_on: Date.today, amount: "50.00" }
      }
      expect(response.body).to include('id="expense-correct-unit-error"')

      allow(Expenses::CorrectService).to receive(:call).and_return(
        Dry::Monads::Failure(err_struct.new("Generic unmapped error", {}))
      )
      post correct_expense_url(expense), params: {
        expense: { property_id: property.id, expense_kind: "repairs", paid_on: Date.today, amount: "50.00" }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "executes the complete Expense-correction workflow with active reimbursements without historical doubling" do
      # 1. Jan 1: Post expense $300
      post expenses_url, params: {
        expense: {
          property_id: property.id,
          rentable_unit_id: unit.id,
          expense_kind: "utilities",
          amount: "300.00",
          paid_on: "2026-01-01",
          description: "Water bill Jan"
        }
      }
      expect(response).to redirect_to(expense_path(Expense.last))
      original_expense = Expense.last

      # 2. Jan 1: Create reimbursement $150 via UI endpoint
      post expense_reimbursements_url(original_expense), params: {
        charge: {
          tenancy_id: tenancy.id,
          amount: "150.00",
          charge_date: "2026-01-01",
          due_on: "2026-01-01",
          description: "Water reimbursement"
        }
      }
      expect(response).to redirect_to(expense_path(original_expense))

      # Verify point-in-time tenancy balance before correction
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 7, 1))).to eq(150.0)
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 8, 16))).to eq(150.0)

      # 3. Aug 16: Correct source Expense through UI workflow to $350
      post correct_expense_url(original_expense), params: {
        expense: {
          property_id: property.id,
          rentable_unit_id: unit.id,
          expense_kind: "utilities",
          amount: "350.00",
          paid_on: "2026-01-01",
          description: "Water bill Jan (adjusted)"
        }
      }
      expect(response).to redirect_to(expense_path(Expense.last))
      replacement_expense = Expense.last
      expect(replacement_expense.id).not_to eq(original_expense.id)

      # 4. Verify historical and current tenancy balances remain exactly $150 (no doubling on Jul 1!)
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 7, 1))).to eq(150.0)
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 8, 16))).to eq(150.0)

      # 5. Add additional reimbursement on replacement expense for the extra $50
      post expense_reimbursements_url(replacement_expense), params: {
        charge: {
          tenancy_id: tenancy.id,
          amount: "50.00",
          charge_date: "2026-01-01",
          due_on: "2026-01-01",
          description: "Additional water share"
        }
      }
      expect(response).to redirect_to(expense_path(replacement_expense))

      # Tenancy balance is now $200
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 7, 1))).to eq(200.0)
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 8, 16))).to eq(200.0)
    end
  end

  describe "POST /expenses/:id/void" do
    it "voids the expense and reverses journal entry" do
      expect {
        post void_expense_url(expense)
      }.to change(JournalEntry, :count).by(1)

      expect(response).to redirect_to(expense_url(expense))
      expect(expense.reload).to be_voided
    end

    it "handles void failure from service" do
      allow(Expenses::VoidService).to receive(:call).and_return(
        ServiceResult.failure(error: "Void failed", code: :void_error)
      )
      post void_expense_url(expense)
      expect(response).to redirect_to(expense_url(expense))
      expect(flash[:alert]).to eq("Void failed")
    end

    it "rejects voiding if active reimbursements exist" do
      Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy,
        amount_cents: 5_000
      )

      post void_expense_url(expense)
      expect(response).to redirect_to(expense_url(expense))
      expect(flash[:alert]).to include("active reimbursement charges")
      expect(expense.reload).not_to be_voided
    end
  end
end
