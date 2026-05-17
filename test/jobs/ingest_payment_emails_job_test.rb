require "test_helper"
require "net/imap"
require "mail"

class IngestPaymentEmailsJobTest < ActiveJob::TestCase
  class MockIMAP
    attr_reader :logged_in, :selected_mailbox, :searched, :fetched, :stored_flags, :logged_out, :disconnected
    attr_reader :server, :port, :ssl

    def initialize(server, port, ssl, raw_source)
      @server = server
      @port = port
      @ssl = ssl
      @raw_source = raw_source
      @logged_in = false
      @selected_mailbox = nil
      @searched = false
      @fetched = false
      @stored_flags = nil
      @logged_out = false
      @disconnected = false
    end

    def login(username, password)
      @logged_in = (username == "kyle@example.com" && password == "app-password")
    end

    def select(mailbox)
      @selected_mailbox = mailbox
    end

    def search(query)
      @searched = true
      [ 42 ]
    end

    def fetch(message_id, format)
      @fetched = true
      # Capture in a local variable to bypass block dynamic scope lookup of instance variables
      local_source = @raw_source
      msg = Object.new
      msg.define_singleton_method(:attr) { { "RFC822" => local_source } }
      [ msg ]
    end

    def store(message_id, command, flags)
      @stored_flags = { id: message_id, cmd: command, flags: flags }
    end

    def logout
      @logged_out = true
    end

    def disconnect
      @disconnected = true
    end
  end

  setup do
    @user = users(:one)
    @config = EmailConfiguration.create!(
      user: @user,
      imap_server: "imap.example.com",
      imap_port: 993,
      username: "kyle@example.com",
      password: "app-password",
      mailbox: "INBOX",
      ssl: true,
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
    @scheduled_rent = @lease.scheduled_rents.order(:due_date).first

    # Simple stub override for Net::IMAP.new supporting keyword arguments
    class << Net::IMAP
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
    # Reset Net::IMAP.new mock block
    Net::IMAP.mock_new_block = nil
  end

  def read_eml_fixture(filename)
    File.read(Rails.root.join("test/fixtures/emails", filename))
  end

  test "polls mailboxes, processes unseen emails, and marks them seen" do
    raw_source = read_eml_fixture("zelle-rent-payment.eml")
    mock_imap = nil

    Net::IMAP.mock_new_block = ->(server, port: nil, ssl: nil) {
      mock_imap = MockIMAP.new(server, port, ssl, raw_source)
    }

    assert_difference -> { RentPayment.count } => 1 do
      IngestPaymentEmailsJob.perform_now
    end

    assert_not_nil mock_imap
    assert_equal "imap.example.com", mock_imap.server
    assert mock_imap.logged_in
    assert_equal "INBOX", mock_imap.selected_mailbox
    assert mock_imap.searched
    assert mock_imap.fetched
    assert_equal({ id: 42, cmd: "+FLAGS", flags: [ :Seen ] }, mock_imap.stored_flags)
    assert mock_imap.logged_out
    assert mock_imap.disconnected

    @config.reload
    assert_not_nil @config.last_polled_at
  end

  test "skips disabled configurations" do
    @config.update!(enabled: false)

    Net::IMAP.mock_new_block = ->(*args, **kwargs) {
      flunk "Should not poll disabled configuration"
    }

    assert_no_difference -> { RentPayment.count } do
      IngestPaymentEmailsJob.perform_now
    end
  end
end
