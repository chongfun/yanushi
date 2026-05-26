require 'rails_helper'

RSpec.describe "Sessions", type: :request do
  let!(:user) { create(:user) }

  describe "GET /new" do
    it "renders a successful response" do
      get new_session_path
      expect(response).to be_successful
    end
  end

  describe "POST /create" do
    context "with valid credentials" do
      it "redirects to root and sets session cookie" do
        post session_path, params: { email: user.email, password: "password" }
        expect(response).to redirect_to(root_path)
        expect(cookies[:session_id]).to be_present
      end
    end

    context "with invalid credentials" do
      it "redirects to new session path and does not set session cookie" do
        post session_path, params: { email: user.email, password: "wrong" }
        expect(response).to redirect_to(new_session_path)
        expect(cookies[:session_id]).to be_nil
      end

      it "renders turbo_stream error on login failure" do
        post session_path, params: { email: user.email, password: "wrong" }, as: :turbo_stream
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("turbo-stream")
        expect(response.body).to include("flash-messages")
      end
    end
  end

  describe "DELETE /destroy" do
    it "signs out and redirects to new session path" do
      sign_in_as(user)
      delete session_path
      expect(response).to redirect_to(new_session_path)
      expect(cookies[:session_id]).to be_blank
    end
  end
end
