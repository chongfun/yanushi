require 'rails_helper'

RSpec.describe "Passwords", type: :request do
  include ActiveJob::TestHelper

  let!(:user) { create(:user) }

  describe "GET /new" do
    it "renders a successful response" do
      get new_password_path
      expect(response).to be_successful
    end
  end

  describe "POST /create" do
    it "enqueues reset email for existing user and redirects to login" do
      expect {
        post passwords_path, params: { email: user.email }
      }.to have_enqueued_mail(PasswordsMailer, :reset).with(user)

      expect(response).to redirect_to(new_session_path)
      follow_redirect!
      expect(response.body).to include("Password reset instructions sent")
    end

    it "enqueues reset email for existing user and renders turbo_stream" do
      expect {
        post passwords_path, params: { email: user.email }, as: :turbo_stream
      }.to have_enqueued_mail(PasswordsMailer, :reset).with(user)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("turbo-stream")
      expect(response.body).to include("flash-messages")
    end

    it "redirects but does not enqueue email for missing user" do
      expect {
        post passwords_path, params: { email: "missing@example.com" }
      }.not_to have_enqueued_mail(PasswordsMailer, :reset)

      expect(response).to redirect_to(new_session_path)
      follow_redirect!
      expect(response.body).to include("Password reset instructions sent")
    end
  end

  describe "GET /edit" do
    it "renders successful edit form with valid token" do
      token = user.password_reset_token
      get edit_password_path(token)
      expect(response).to be_successful
    end

    it "redirects to new password path with invalid token" do
      get edit_password_path("invalid_token")
      expect(response).to redirect_to(new_password_path)
      follow_redirect!
      expect(response.body).to include("Password reset link is invalid")
    end
  end

  describe "PUT /update" do
    it "resets password with matching password confirmation" do
      token = user.password_reset_token
      expect {
        put password_path(token), params: { password: "newpassword", password_confirmation: "newpassword" }
      }.to change { user.reload.password_digest }

      expect(response).to redirect_to(new_session_path)
      follow_redirect!
      expect(response.body).to include("Password has been reset")
    end

    it "does not reset password with mismatched passwords" do
      token = user.password_reset_token
      expect {
        put password_path(token), params: { password: "newpassword", password_confirmation: "mismatch" }
      }.not_to change { user.reload.password_digest }

      expect(response).to redirect_to(edit_password_path(token))
      follow_redirect!
      expect(response.body).to include("Passwords did not match")
    end

    it "does not reset password and renders turbo_stream error on mismatch" do
      token = user.password_reset_token
      expect {
        put password_path(token), params: { password: "newpassword", password_confirmation: "mismatch" }, as: :turbo_stream
      }.not_to change { user.reload.password_digest }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("turbo-stream")
      expect(response.body).to include("flash-messages")
    end
  end
end
