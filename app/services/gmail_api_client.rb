require "google/apis/gmail_v1"
require "googleauth"
require "base64"

class GmailApiClient
  SCOPE = "https://www.googleapis.com/auth/gmail.modify"

  def initialize(config)
    @config = config
    @service = Google::Apis::GmailV1::GmailService.new
    @service.authorization = build_credentials
  end

  # Returns an array of message stubs (id only) for unread messages
  def list_unread_messages
    response = @service.list_user_messages("me", q: "is:unread")
    response.messages || []
  end

  # Returns the raw RFC822 source string for a given message ID
  def get_raw_message(message_id)
    msg = @service.get_user_message("me", message_id, format: "raw")
    # Gmail returns raw as URL-safe Base64; decode to get RFC822 source
    Base64.urlsafe_decode64(msg.raw)
  end

  # Remove the UNREAD label so the message is marked as read
  def mark_as_read(message_id)
    modify_request = Google::Apis::GmailV1::ModifyMessageRequest.new(
      remove_label_ids: [ "UNREAD" ]
    )
    @service.modify_message("me", message_id, modify_request)
  end

  private

  def build_credentials
    client_id = Google::Auth::ClientId.new(
      Rails.application.credentials.dig(:google, :client_id) || "mock_client_id",
      Rails.application.credentials.dig(:google, :client_secret) || "mock_client_secret"
    )

    credentials = Google::Auth::UserRefreshCredentials.new(
      client_id:     client_id.id,
      client_secret: client_id.secret,
      scope:         SCOPE,
      refresh_token: @config.google_refresh_token,
      access_token:  @config.google_access_token,
      expires_at:    @config.google_token_expires_at
    )

    # Auto-refresh if expired and persist the new tokens
    if credentials.expired? && @config.google_refresh_token.present?
      begin
        credentials.fetch_access_token!
        @config.update!(
          google_access_token:     credentials.access_token,
          google_token_expires_at: Time.at(credentials.issued_at.to_i + credentials.expires_in)
        ) if @config.persisted?
      rescue => e
        Rails.logger.error("Failed to refresh Gmail API token: #{e.message}")
      end
    end

    credentials
  end
end
