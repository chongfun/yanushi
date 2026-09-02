require "rails_helper"

RSpec.describe "PropertyTaxReviewResolutions", type: :request do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:other_user) { create(:user) }
  let(:other_property) { create(:property, user: other_user) }
  let(:tenancy) { create(:tenancy, property: property) }
  let(:party) { create(:party, user: user) }
  let(:deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)
    post session_path, params: { email: user.email, password: "password" }
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: deposit,
      party: party,
      amount_cents: 200_000,
      occurred_on: Date.new(2025, 1, 1)
    )
    charge = Charges::CreateFeeService.call(
      tenancy: tenancy,
      charge_kind: "other",
      description: "Repair fee",
      amount_cents: 150_000,
      charge_date: Date.new(2025, 6, 1)
    ).value!.data[:charge]
    SecurityDepositTransactions::ApplyService.call(
      security_deposit: deposit,
      charge: charge,
      amount_cents: 150_000,
      occurred_on: Date.new(2025, 6, 15)
    )
  end

  let(:entry) { JournalEntry.find_by!(event_type: "deposit_applied") }

  describe "POST /properties/:property_id/tax_review_resolutions" do
    it "creates a resolution with include_in_rents treatment and redirects to schedule_e" do
      expect {
        post property_tax_review_resolutions_path(property), params: {
          property_tax_review_resolution: {
            journal_entry_id: entry.id,
            tax_year: 2025,
            treatment: "include_in_rents",
            notes: "Rent recovery"
          }
        }
      }.to change(PropertyTaxReviewResolution, :count).by(1)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:notice]).to include("Tax treatment for Journal Entry ##{entry.id} was successfully recorded.")

      resolution = PropertyTaxReviewResolution.last
      expect(resolution.treatment).to eq("include_in_rents")
      expect(resolution.tax_year).to eq(2025)
      expect(resolution.journal_entry_id).to eq(entry.id)
    end

    it "creates a resolution with Turbo Stream format and updates schedule E components" do
      expect {
        post property_tax_review_resolutions_path(property, format: :turbo_stream), params: {
          property_tax_review_resolution: {
            journal_entry_id: entry.id,
            tax_year: 2025,
            treatment: "include_in_rents"
          }
        }
      }.to change(PropertyTaxReviewResolution, :count).by(1)

      expect(response).to be_successful
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('target="schedule_e_readiness"')
      expect(response.body).to include('target="schedule_e_projection"')
      expect(response.body).to include('target="schedule_e_review"')
    end

    it "renders validation errors inside schedule_e_review with 422 and without success toast on Turbo Stream failure" do
      unmapped_account = user.accounts.create!(name: "Custom Roof", key: "expense_custom_roof_err", account_type: "expense")
      expense = create(:expense, property: property)
      expense_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "expense_posted", source: expense)
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: 300_000, account: unmapped_account)

      expect {
        post property_tax_review_resolutions_path(property, format: :turbo_stream), params: {
          property_tax_review_resolution: {
            journal_entry_id: expense_entry.id,
            tax_year: 2025,
            treatment: "map_to_schedule_e_category",
            schedule_e_category: ""
          }
        }
      }.not_to change(PropertyTaxReviewResolution, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('target="schedule_e_review"')
      expect(response.body).to include("Schedule e category can&#39;t be blank")
      expect(response.body).not_to include("Tax treatment was successfully recorded")
      expect(response.body).not_to include('target="schedule_e_readiness"')
    end

    it "creates a resolution with exclude treatment" do
      expect {
        post property_tax_review_resolutions_path(property), params: {
          property_tax_review_resolution: {
            journal_entry_id: entry.id,
            tax_year: 2025,
            treatment: "exclude"
          }
        }
      }.to change(PropertyTaxReviewResolution, :count).by(1)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(PropertyTaxReviewResolution.last.treatment).to eq("exclude")
    end

    it "creates a resolution mapping an unmapped expense to a Schedule E category" do
      unmapped_account = user.accounts.create!(name: "Custom Roof", key: "expense_custom_roof", account_type: "expense")
      expense = create(:expense, property: property)
      expense_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "expense_posted", source: expense)
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: 300_000, account: unmapped_account)

      expect {
        post property_tax_review_resolutions_path(property), params: {
          property_tax_review_resolution: {
            journal_entry_id: expense_entry.id,
            tax_year: 2025,
            treatment: "map_to_schedule_e_category",
            schedule_e_category: "repairs"
          }
        }
      }.to change(PropertyTaxReviewResolution, :count).by(1)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      resolution = PropertyTaxReviewResolution.last
      expect(resolution.treatment).to eq("map_to_schedule_e_category")
      expect(resolution.schedule_e_category).to eq("repairs")
    end

    it "rejects include_in_rents for an unmapped expense entry" do
      unmapped_account = user.accounts.create!(name: "Custom Roof", key: "expense_custom_roof_2", account_type: "expense")
      expense = create(:expense, property: property)
      expense_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "expense_posted", source: expense)
      create(:posting, journal_entry: expense_entry, property: property, amount_cents: 300_000, account: unmapped_account)

      expect {
        post property_tax_review_resolutions_path(property), params: {
          property_tax_review_resolution: {
            journal_entry_id: expense_entry.id,
            tax_year: 2025,
            treatment: "include_in_rents"
          }
        }
      }.not_to change(PropertyTaxReviewResolution, :count)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:alert]).to include("Failed to record tax treatment: Treatment cannot include an expense or non-cash/deposit entry in rental income")
    end

    it "rejects resolving another user's JournalEntry with my property" do
      other_entry = create(:journal_entry, user: other_user, occurred_on: Date.new(2025, 5, 1), source: other_property)
      create(:posting, journal_entry: other_entry, property: other_property, amount_cents: 10_000, account: other_user.accounts.find_by!(key: "cash"))

      expect {
        post property_tax_review_resolutions_path(property), params: {
          property_tax_review_resolution: {
            journal_entry_id: other_entry.id,
            tax_year: 2025,
            treatment: "exclude"
          }
        }
      }.not_to change(PropertyTaxReviewResolution, :count)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:alert]).to include("Failed to record tax treatment: Journal entry must belong to the same user as the property")
    end

    it "rejects resolving a JournalEntry for a mismatched tax year" do
      expect {
        post property_tax_review_resolutions_path(property), params: {
          property_tax_review_resolution: {
            journal_entry_id: entry.id,
            tax_year: 2026,
            treatment: "exclude"
          }
        }
      }.not_to change(PropertyTaxReviewResolution, :count)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2026))
      expect(flash[:alert]).to include("Failed to record tax treatment: Tax year must match the year the journal entry occurred (2025)")
    end

    it "redirects with alert when tax_year is invalid" do
      post property_tax_review_resolutions_path(property), params: {
        property_tax_review_resolution: {
          journal_entry_id: entry.id,
          tax_year: "garbage",
          treatment: "exclude"
        }
      }
      expect(response).to redirect_to(schedule_e_property_path(property, year: Date.current.year))
      expect(flash[:alert]).to include("Invalid tax year 'garbage'")
    end

    it "handles concurrent creation by rescuing ActiveRecord::RecordNotUnique and updating" do
      create(:property_tax_review_resolution, property: property, journal_entry: entry, tax_year: 2025, treatment: "include_in_rents")

      first_call = true
      allow_any_instance_of(PropertyTaxReviewResolution).to receive(:save) do |instance|
        if first_call && instance.new_record?
          first_call = false
          raise ActiveRecord::RecordNotUnique
        else
          instance.send(:create_or_update)
        end
      end

      post property_tax_review_resolutions_path(property), params: {
        property_tax_review_resolution: {
          journal_entry_id: entry.id,
          tax_year: 2025,
          treatment: "exclude"
        }
      }

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:notice]).to include("Tax treatment for Journal Entry ##{entry.id} was successfully updated.")
      expect(PropertyTaxReviewResolution.find_by(journal_entry: entry).treatment).to eq("exclude")
    end

    it "creates a resolution for a prior-year original entry and redirects back to return_to_year" do
      expect {
        post property_tax_review_resolutions_path(property), params: {
          return_to_year: 2026,
          property_tax_review_resolution: {
            journal_entry_id: entry.id, # 2025 entry
            tax_year: 2025,
            treatment: "include_in_rents"
          }
        }
      }.to change(PropertyTaxReviewResolution, :count).by(1)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2026))
      expect(flash[:notice]).to include("Tax treatment for Journal Entry ##{entry.id} was successfully recorded.")
    end

    it "handles invalid return_to_year gracefully by falling back to resolution tax_year" do
      expect {
        post property_tax_review_resolutions_path(property), params: {
          return_to_year: "garbage",
          property_tax_review_resolution: {
            journal_entry_id: entry.id,
            tax_year: 2025,
            treatment: "include_in_rents"
          }
        }
      }.to change(PropertyTaxReviewResolution, :count).by(1)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(response).to have_http_status(:found)
    end

    it "prevents creating resolution on another user's property" do
      post property_tax_review_resolutions_path(other_property), params: {
        property_tax_review_resolution: {
          journal_entry_id: entry.id,
          tax_year: 2025,
          treatment: "include_in_rents"
        }
      }
      expect(response).to have_http_status(:not_found)
    end

    it "rejects resolution creation for an ordinary already-mapped expense entry" do
      expense = create(:expense, property: property, expense_kind: "repairs", amount_cents: 10_000)
      mapped_entry = create(:journal_entry, user: user, occurred_on: Date.new(2025, 5, 1), event_type: "expense_posted", source: expense)
      create(:posting, journal_entry: mapped_entry, property: property, amount_cents: 10_000, account: user.accounts.find_by!(key: "expense_repairs"))
      create(:posting, journal_entry: mapped_entry, property: property, amount_cents: -10_000, account: user.accounts.find_by!(key: "cash"))

      expect {
        post property_tax_review_resolutions_path(property), params: {
          property_tax_review_resolution: {
            journal_entry_id: mapped_entry.id,
            tax_year: 2025,
            treatment: "exclude"
          }
        }
      }.not_to change(PropertyTaxReviewResolution, :count)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:alert]).to include("does not require tax review")

      expect {
        post property_tax_review_resolutions_path(property), params: {
          property_tax_review_resolution: {
            journal_entry_id: mapped_entry.id,
            tax_year: 2025,
            treatment: "map_to_schedule_e_category",
            schedule_e_category: "advertising"
          }
        }
      }.not_to change(PropertyTaxReviewResolution, :count)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:alert]).to include("does not require tax review")
    end

    it "handles RecordNotUnique when existing record is not found" do
      allow_any_instance_of(PropertyTaxReviewResolution).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

      post property_tax_review_resolutions_path(property), params: {
        property_tax_review_resolution: {
          journal_entry_id: entry.id,
          tax_year: 2025,
          treatment: "include_in_rents"
        }
      }

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:alert]).to include("Failed to record tax treatment")
    end
  end

  describe "DELETE /properties/:property_id/tax_review_resolutions/:id" do
    let!(:resolution) do
      create(:property_tax_review_resolution, property: property, journal_entry: entry, tax_year: 2025, treatment: "include_in_rents")
    end

    it "deletes the resolution and restores the review item" do
      expect {
        delete property_tax_review_resolution_path(property, resolution)
      }.to change(PropertyTaxReviewResolution, :count).by(-1)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(flash[:notice]).to include("Tax treatment resolution removed; review item restored.")
    end

    it "deletes the resolution and redirects back to return_to_year when specified" do
      expect {
        delete property_tax_review_resolution_path(property, resolution, return_to_year: 2026)
      }.to change(PropertyTaxReviewResolution, :count).by(-1)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2026))
    end

    it "handles invalid return_to_year gracefully on destroy by falling back to resolution tax_year" do
      expect {
        delete property_tax_review_resolution_path(property, resolution, return_to_year: "invalid")
      }.to change(PropertyTaxReviewResolution, :count).by(-1)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2025))
      expect(response).to have_http_status(:found)
    end

    it "deletes the resolution via Turbo Stream format and updates schedule E components" do
      expect {
        delete property_tax_review_resolution_path(property, resolution, format: :turbo_stream)
      }.to change(PropertyTaxReviewResolution, :count).by(-1)

      expect(response).to be_successful
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('target="schedule_e_readiness"')
      expect(response.body).to include('target="schedule_e_projection"')
      expect(response.body).to include('target="schedule_e_review"')
    end
  end
end
