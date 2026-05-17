require "test_helper"
require "mail"
require "ostruct"

class IngestPaymentEmailsJobTest < ActiveJob::TestCase
  setup do
    travel_to Date.parse("2024-08-01")
    @user = users(:one)
    @config = EmailConfiguration.create!(
      user: @user,
      gmail_address: "kyle@workspace.com",
      google_refresh_token: "refresh",
      google_access_token: "access",
      google_token_expires_at: Time.current + 1.hour,
      enabled: true
    )

    # Create tenant and lease for the processed email in fixture to match successfully
    @tenant = Tenant.create!(user: @user, name: "Kristina Page")
    @tenant.tenant_aliases.create!(name: "KRISTINA M PAGE")
    @property = RentalProperty.create!(user: @user, address: "123 St", property_type: 1, square_footage: 1000)
    @lease = Lease.create!(
      rental_property: @property,
      commencement_date: Date.parse("2024-01-01"),
      termination_date: Date.parse("2024-12-31"),
      annual_rental_amount: 14400.0,
      security_deposit: 1200.0,
      lease_type: 1
    )
    LeaseTenant.create!(lease: @lease, tenant: @tenant)

    # Simple stub override for GmailApiClient.new
    class << GmailApiClient
      alias_method :original_new, :new rescue nil
      attr_accessor :mock_new_block
      def new(*args, **kwargs)
        if mock_new_block
          mock_new_block.call(*args, **kwargs)
        else
          original_new(*args, **kwargs)
        end
      end
    end
  end

  teardown do
    GmailApiClient.mock_new_block = nil
  end

  def read_eml_fixture(filename)
    File.read(Rails.root.join("test/fixtures/emails", filename))
  end

  test "polls gmail_api configurations using GmailApiClient and processes payments" do
    raw_source = read_eml_fixture("zelle-rent-payment.eml")

    mock_client = Object.new
    mock_client.define_singleton_method(:list_unread_messages) do
      [ OpenStruct.new(id: "gmail_msg_1") ]
    end
    mock_client.define_singleton_method(:get_raw_message) do |message_id|
      raise "Invalid ID" unless message_id == "gmail_msg_1"
      raw_source
    end

    marked_as_read = false
    mock_client.define_singleton_method(:mark_as_read) do |message_id|
      marked_as_read = true if message_id == "gmail_msg_1"
    end

    GmailApiClient.mock_new_block = ->(config) {
      raise "Expected config to be @config" unless config == @config
      mock_client
    }

    assert_difference -> { TenantPayment.count } => 1 do
      IngestPaymentEmailsJob.perform_now
    end

    assert marked_as_read
    @config.reload
    assert_not_nil @config.last_polled_at
  end

  test "skips disabled configurations" do
    @config.update!(enabled: false)

    GmailApiClient.mock_new_block = ->(*args, **kwargs) {
      flunk "Should not poll disabled configuration"
    }

    assert_no_difference -> { TenantPayment.count } do
      IngestPaymentEmailsJob.perform_now
    end
  end
end
