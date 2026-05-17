require "test_helper"
require "ostruct"

class GmailApiClientTest < ActiveSupport::TestCase
  class MockGmailService
    attr_reader :list_user_messages_calls, :get_user_message_calls, :modify_message_calls

    def initialize(list_response: nil, get_response: nil)
      @list_response = list_response
      @get_response = get_response
      @list_user_messages_calls = []
      @get_user_message_calls = []
      @modify_message_calls = []
    end

    def list_user_messages(user_id, q:)
      @list_user_messages_calls << { user_id: user_id, q: q }
      @list_response
    end

    def get_user_message(user_id, message_id, format:)
      @get_user_message_calls << { user_id: user_id, message_id: message_id, format: format }
      @get_response
    end

    def modify_message(user_id, message_id, request)
      @modify_message_calls << { user_id: user_id, message_id: message_id, request: request }
      nil
    end
  end

  setup do
    @user = users(:one)
    @config = @user.build_email_configuration(
      provider: :gmail_api,
      gmail_address: "kyle@workspace.com",
      google_refresh_token: "mock_refresh_token",
      google_access_token: "mock_access_token",
      google_token_expires_at: 1.hour.from_now
    )

    # Redefine dig on Rails.application.credentials dynamically for testing
    credentials = Rails.application.credentials
    class << credentials
      alias_method :orig_dig, :dig if method_defined?(:dig) && !method_defined?(:orig_dig)
      def dig(*args)
        if args == [ :google, :client_id ]
          "mock_client_id"
        elsif args == [ :google, :client_secret ]
          "mock_client_secret"
        elsif respond_to?(:orig_dig)
          orig_dig(*args)
        else
          nil
        end
      end
    end

    @client = GmailApiClient.new(@config)
  end

  teardown do
    credentials = Rails.application.credentials
    class << credentials
      if method_defined?(:orig_dig)
        alias_method :dig, :orig_dig
        remove_method :orig_dig
      end
    end
  end

  test "list_unread_messages returns array of message stubs" do
    mock_response = OpenStruct.new(
      messages: [
        OpenStruct.new(id: "msg123"),
        OpenStruct.new(id: "msg456")
      ]
    )
    mock_service = MockGmailService.new(list_response: mock_response)
    @client.instance_variable_set(:@service, mock_service)

    messages = @client.list_unread_messages
    assert_equal 2, messages.size
    assert_equal "msg123", messages.first.id

    assert_equal 1, mock_service.list_user_messages_calls.size
    assert_equal "me", mock_service.list_user_messages_calls.first[:user_id]
    assert_equal "is:unread", mock_service.list_user_messages_calls.first[:q]
  end

  test "get_raw_message returns decoded RFC822 string" do
    encoded_source = Base64.urlsafe_encode64("Subject: Hello World\r\n\r\nBody here")
    mock_msg = OpenStruct.new(raw: encoded_source)
    mock_service = MockGmailService.new(get_response: mock_msg)
    @client.instance_variable_set(:@service, mock_service)

    raw_source = @client.get_raw_message("msg123")
    assert_equal "Subject: Hello World\r\n\r\nBody here", raw_source

    assert_equal 1, mock_service.get_user_message_calls.size
    assert_equal "msg123", mock_service.get_user_message_calls.first[:message_id]
    assert_equal "raw", mock_service.get_user_message_calls.first[:format]
  end

  test "mark_as_read removes UNREAD label" do
    mock_service = MockGmailService.new
    @client.instance_variable_set(:@service, mock_service)

    @client.mark_as_read("msg123")

    assert_equal 1, mock_service.modify_message_calls.size
    call = mock_service.modify_message_calls.first
    assert_equal "msg123", call[:message_id]
    assert_equal [ "UNREAD" ], call[:request].remove_label_ids
  end
end
