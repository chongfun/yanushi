require "rails_helper"

RSpec.describe "Inbox", type: :request do
  let(:user) { create(:user) }

  describe "GET /inbox" do
    context "when authenticated" do
      before do
        sign_in_as(user)
      end

      it "routes to imported_transactions#index and returns 200" do
        get inbox_url
        expect(response).to be_successful
        expect(response.body).to include("Transaction Ingestion")
      end
    end

    context "when unauthenticated" do
      it "redirects to the login page" do
        get inbox_url
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
