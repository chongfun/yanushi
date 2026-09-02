require "rails_helper"

RSpec.describe "Portfolio", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /portfolio" do
    context "when authenticated" do
      before do
        sign_in_as(user)
      end

      it "returns a successful response and renders properties" do
        property = create(:property, user: user, address: "123 Portfolio St")
        other_property = create(:property, user: other_user, address: "999 Secret Ave")

        get portfolio_url
        expect(response).to be_successful
        expect(response.body).to include("Portfolio")
        expect(response.body).to include("123 Portfolio St")
        expect(response.body).not_to include("999 Secret Ave")
      end

      it "renders empty state when user has no properties" do
        get portfolio_url
        expect(response).to be_successful
        expect(response.body).to include("Add your first property")
      end
    end

    context "when unauthenticated" do
      it "redirects to the login page" do
        get portfolio_url
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
