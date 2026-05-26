require 'rails_helper'

RSpec.describe "Dashboards", type: :request do
  let(:user) { create(:user) }


  describe "GET /show" do
    context "when authenticated" do
      before do
        sign_in_as(user)
      end

      it "renders the dashboard index page successfully" do
        get dashboards_index_url
        expect(response).to be_successful
      end
    end

    context "when unauthenticated" do
      it "redirects to the login page" do
        get dashboards_index_url
        expect(response).to redirect_to(new_session_path)
      end
    end
  end

  describe "authenticated? helper method" do
    context "when authenticated" do
      before { sign_in_as(user) }
      it "returns true" do
        get dashboards_index_url
        expect(controller.send(:authenticated?)).to be_truthy
      end
    end

    context "when unauthenticated" do
      it "returns false" do
        get dashboards_index_url
        expect(controller.send(:authenticated?)).to be_falsey
      end
    end
  end
end
