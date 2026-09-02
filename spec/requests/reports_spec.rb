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
        property = create(:property, user: user, address: "777 Tax Way")
        other_property = create(:property, user: other_user, address: "888 Other Way")

        get reports_url
        expect(response).to be_successful
        expect(response.body).to include("Reports")
        expect(response.body).to include("777 Tax Way")
        expect(response.body).to include(schedule_e_property_path(property))
        expect(response.body).not_to include("888 Other Way")
      end

      it "renders empty state when user has no properties" do
        get reports_url
        expect(response).to be_successful
        expect(response.body).to include("No properties found")
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
