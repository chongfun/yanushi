require "net/http"
require "json"

class GoogleAuthController < ApplicationController
  SCOPE = "https://www.googleapis.com/auth/gmail.modify"

  def redirect
    client_id = Rails.application.credentials.dig(:google, :client_id)
    redirect_uri = auth_google_callback_url

    url = "https://accounts.google.com/o/oauth2/v2/auth?" + {
      client_id:     client_id,
      redirect_uri:  redirect_uri,
      response_type: "code",
      scope:         SCOPE,
      access_type:   "offline",
      prompt:        "consent"
    }.to_query

    redirect_to url, allow_other_host: true
  end

  def callback
    token_response = exchange_code_for_tokens(params[:code])

    config = Current.user.email_configuration || Current.user.build_email_configuration
    config.update!(
      gmail_address:           fetch_gmail_address(token_response),
      google_refresh_token:    token_response["refresh_token"],
      google_access_token:     token_response["access_token"],
      google_token_expires_at: Time.current + token_response["expires_in"].to_i.seconds,
      enabled:                 true
    )

    redirect_to email_configuration_path, notice: "Google Workspace account connected successfully."
  end

  private

  def exchange_code_for_tokens(code)
    uri = URI("https://oauth2.googleapis.com/token")
    response = Net::HTTP.post_form(uri, {
      code:          code,
      client_id:     Rails.application.credentials.dig(:google, :client_id),
      client_secret: Rails.application.credentials.dig(:google, :client_secret),
      redirect_uri:  auth_google_callback_url,
      grant_type:    "authorization_code"
    })
    JSON.parse(response.body)
  end

  def fetch_gmail_address(token_response)
    service = Google::Apis::GmailV1::GmailService.new
    service.authorization = Google::Auth::UserRefreshCredentials.new(
      access_token: token_response["access_token"]
    )
    profile = service.get_user_profile("me")
    profile.email_address
  end
end
