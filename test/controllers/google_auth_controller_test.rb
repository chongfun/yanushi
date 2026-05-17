require "test_helper"
require "ostruct"

class GoogleAuthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)

    # Redefine dig on Rails.application.credentials dynamically
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

  test "should redirect to google oauth page" do
    get auth_google_url
    assert_response :redirect
    assert_match /accounts\.google\.com/, response.redirect_url
    assert_match /client_id=mock_client_id/, response.redirect_url
  end

  test "should handle google callback and store refresh token" do
    # Define mock methods on GoogleAuthController to avoid external HTTP requests in tests
    GoogleAuthController.class_eval do
      alias_method :original_exchange_code_for_tokens, :exchange_code_for_tokens rescue nil
      alias_method :original_fetch_gmail_address, :fetch_gmail_address rescue nil

      def exchange_code_for_tokens(code)
        {
          "access_token" => "new_access_token",
          "refresh_token" => "new_refresh_token",
          "expires_in" => 3600
        }
      end

      def fetch_gmail_address(token_response)
        "kyle@workspace.com"
      end
    end

    assert_difference -> { EmailConfiguration.count } => 1 do
      get auth_google_callback_url, params: { code: "mock_auth_code" }
    end

    assert_redirected_to email_configuration_url
    assert_equal "Google Workspace account connected successfully.", flash[:notice]

    config = @user.reload.email_configuration
    assert_equal "kyle@workspace.com", config.gmail_address
    assert_equal "new_refresh_token", config.google_refresh_token
    assert_equal "new_access_token", config.google_access_token
    assert_not_nil config.google_token_expires_at

    # Restore original methods
    GoogleAuthController.class_eval do
      if method_defined?(:original_exchange_code_for_tokens)
        alias_method :exchange_code_for_tokens, :original_exchange_code_for_tokens
        remove_method :original_exchange_code_for_tokens
      end
      if method_defined?(:original_fetch_gmail_address)
        alias_method :fetch_gmail_address, :original_fetch_gmail_address
        remove_method :original_fetch_gmail_address
      end
    end
  end
end
