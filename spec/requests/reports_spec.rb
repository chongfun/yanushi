require "rails_helper"

RSpec.describe "Reports", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /reports" do
    context "when authenticated" do
      before do
        sign_in_as(user)
      end

      it "returns a successful response and lists properties for Schedule E" do
        property_unconfigured = create(:property, user: user, address: "777 Tax Way")
        property_configured = create(:property, user: user, address: "999 Ready Way")
        create(
          :property_tax_profile,
          property: property_configured,
          tax_year: Date.current.year - 1,
          schedule_e_property_type: "single_family_residence"
        )
        other_property = create(:property, user: other_user, address: "888 Other Way")

        get reports_url
        expect(response).to be_successful
        expect(response.body).to include("Reports")
        expect(response.body).to include("777 Tax Way")
        expect(response.body).to include("Needs tax profile")
        expect(response.body).to include(new_property_tax_profile_path(property_unconfigured, tax_year: Date.current.year - 1))
        expect(response.body).to include("999 Ready Way")
        expect(response.body).to include(schedule_e_property_path(property_configured, year: Date.current.year - 1))
        expect(response.body).not_to include("888 Other Way")
      end

      it "groups the properties that need work above the ready ones" do
        previous_year = Date.current.year - 1
        create(:property, user: user, address: "999 Zebra Way")
        create(:property, user: user, address: "888 Yak St")
        property_ready = create(:property, user: user, address: "111 Ready Ave")
        create(
          :property_tax_profile,
          property: property_ready,
          tax_year: previous_year,
          schedule_e_property_type: "single_family_residence"
        )

        get reports_url
        expect(response).to be_successful

        body = response.body
        expect(body).to include("Needs work")
        expect(body).to include("2<span class=\"sr-only\"> properties need work</span>")

        work_heading = body.index("reports-work-heading")
        ready_heading = body.index("reports-ready-heading")
        expect(work_heading).to be < body.index("888 Yak St")
        expect(body.index("888 Yak St")).to be < body.index("999 Zebra Way")
        expect(body.index("999 Zebra Way")).to be < ready_heading
        expect(ready_heading).to be < body.index("111 Ready Ave")
      end

      it "renders empty state when user has no properties" do
        get reports_url
        expect(response).to be_successful
        expect(response.body).to include("No properties found")
      end

      it "falls back gracefully to previous year when given an invalid year parameter" do
        create(:property, user: user, address: "101 Maple St")
        previous_year = Date.current.year - 1

        # Non-numeric string
        get reports_url, params: { year: "invalid" }
        expect(response).to be_successful
        expect(response.body).to include("selected=\"selected\" value=\"#{previous_year}\"")

        # Out-of-range year
        get reports_url, params: { year: "99999" }
        expect(response).to be_successful
        expect(response.body).to include("selected=\"selected\" value=\"#{previous_year}\"")

        # Distant past
        get reports_url, params: { year: "1800" }
        expect(response).to be_successful
        expect(response.body).to include("selected=\"selected\" value=\"#{previous_year}\"")
      end

      it "renders status rows for a valid explicit year parameter" do
        property = create(:property, user: user, address: "202 Pine St")
        create(:property_tax_profile, property: property, tax_year: 2024, schedule_e_property_type: "single_family_residence")

        get reports_url, params: { year: 2024 }
        expect(response).to be_successful
        expect(response.body).to include("selected=\"selected\" value=\"2024\"")
        expect(response.body).to include("202 Pine St")
        expect(response.body).to include("Ready")
        expect(response.body).to include("No properties need work for 2024.")
      end
    end

    context "when unauthenticated" do
      it "redirects to the login page" do
        get reports_url
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
