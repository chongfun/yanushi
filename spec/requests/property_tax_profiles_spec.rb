require "rails_helper"

RSpec.describe "PropertyTaxProfiles", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user, asset_type: "multifamily") }
  let(:other_property) { create(:property, user: other_user) }

  before do
    post session_path, params: { email: user.email, password: "password" }
  end

  describe "GET /properties/:property_id/tax_profiles/new" do
    it "renders a successful response with unselected property type prompt" do
      get new_property_tax_profile_path(property, tax_year: 2026)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Configure Tax Profile (2026)")
      expect(response.body).to include("Choose Schedule E property type...")
      # Must not preselect multi_family_residence or any type from physical property type
      expect(response.body).not_to include('selected="selected"')

      # When no tax_year param provided, defaults to current year
      get new_property_tax_profile_path(property)
      expect(response).to have_http_status(:ok)
    end

    it "returns 404 for unowned property" do
      get new_property_tax_profile_path(other_property)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /properties/:property_id/tax_profiles" do
    it "creates a new tax profile and redirects to Schedule E worksheet" do
      expect {
        post property_tax_profiles_path(property), params: {
          property_tax_profile: {
            tax_year: 2026,
            schedule_e_property_type: "multi_family_residence"
          }
        }
      }.to change(PropertyTaxProfile, :count).by(1)

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2026))
      follow_redirect!
      expect(response.body).to include("Tax classification for 2026 was successfully configured.")
    end

    it "creates an 'other' tax profile with required description" do
      post property_tax_profiles_path(property), params: {
        property_tax_profile: {
          tax_year: 2026,
          schedule_e_property_type: "other",
          other_description: "Self-storage facility"
        }
      }

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2026))
      profile = property.tax_profiles.find_by(tax_year: 2026)
      expect(profile.schedule_e_property_type).to eq("other")
      expect(profile.other_description).to eq("Self-storage facility")
    end

    it "renders unprocessable_content on validation errors" do
      create(:property_tax_profile, property: property, tax_year: 2026)

      post property_tax_profiles_path(property), params: {
        property_tax_profile: {
          tax_year: 2026,
          schedule_e_property_type: "single_family_residence"
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tax year has already been taken")
    end

    it "rejects tax year outside 1901..2099 with unprocessable_content" do
      post property_tax_profiles_path(property), params: {
        property_tax_profile: {
          tax_year: 2100,
          schedule_e_property_type: "single_family_residence"
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tax year must be less than or equal to 2099")
    end

    it "handles concurrent creation race conditions gracefully by rescuing RecordNotUnique" do
      create(:property_tax_profile, property: property, tax_year: 2026)

      # Simulate race condition where validation passed but database unique constraint triggered
      allow_any_instance_of(PropertyTaxProfile).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

      post property_tax_profiles_path(property), params: {
        property_tax_profile: {
          tax_year: 2026,
          schedule_e_property_type: "single_family_residence"
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tax year has already been taken")
    end

    it "handles RecordNotUnique when existing is nil" do
      allow_any_instance_of(PropertyTaxProfile).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

      post property_tax_profiles_path(property), params: {
        property_tax_profile: {
          tax_year: 2026,
          schedule_e_property_type: "single_family_residence"
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tax year has already been taken")
    end

    it "returns 404 for unowned property" do
      post property_tax_profiles_path(other_property), params: {
        property_tax_profile: {
          tax_year: 2026,
          schedule_e_property_type: "single_family_residence"
        }
      }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /properties/:property_id/tax_profiles/:id/edit" do
    let(:profile) { create(:property_tax_profile, property: property, tax_year: 2026) }

    it "renders a successful response for owned profile" do
      get edit_property_tax_profile_path(property, profile)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Edit Tax Profile (2026)")
    end

    it "returns 404 for unowned property profile" do
      other_profile = create(:property_tax_profile, property: other_property, tax_year: 2026)
      get edit_property_tax_profile_path(other_property, other_profile)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /properties/:property_id/tax_profiles/:id" do
    let(:profile) { create(:property_tax_profile, property: property, tax_year: 2026, schedule_e_property_type: "single_family_residence") }

    it "updates the tax profile and redirects to Schedule E worksheet" do
      patch property_tax_profile_path(property, profile), params: {
        property_tax_profile: {
          schedule_e_property_type: "commercial"
        }
      }

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2026))
      expect(profile.reload.schedule_e_property_type).to eq("commercial")
    end

    it "renders unprocessable_content on invalid updates" do
      patch property_tax_profile_path(property, profile), params: {
        property_tax_profile: {
          schedule_e_property_type: "other",
          other_description: ""
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Other description can&#39;t be blank")
    end

    it "ignores tax_year parameter during update, keeping tax_year immutable" do
      patch property_tax_profile_path(property, profile), params: {
        property_tax_profile: {
          tax_year: 2030,
          schedule_e_property_type: "commercial"
        }
      }

      expect(response).to redirect_to(schedule_e_property_path(property, year: 2026))
      expect(profile.reload.tax_year).to eq(2026)
      expect(profile.schedule_e_property_type).to eq("commercial")
    end
  end
end
