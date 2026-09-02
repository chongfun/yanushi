require "rails_helper"

RSpec.describe "Money", type: :request do
  let(:user) { create(:user) }

  describe "GET /money" do
    context "when authenticated" do
      before do
        sign_in_as(user)
      end

      it "returns a successful response with links to Receipts and Expenses" do
        get money_url
        expect(response).to be_successful
        expect(response.body).to include("Money")
        expect(response.body).to include(receipts_path)
        expect(response.body).to include(expenses_path)
      end
    end

    context "when unauthenticated" do
      it "redirects to the login page" do
        get money_url
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
