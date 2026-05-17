require "net/imap"

class IngestPaymentEmailsJob < ApplicationJob
  queue_as :default

  def perform
    EmailConfiguration.where(enabled: true).find_each do |config|
      poll_mailbox(config)
    rescue => e
      Rails.logger.error "Error polling mailbox for configuration ID #{config.id}: #{e.message}"
      raise if Rails.env.test?
    end
  end

  private

  def poll_mailbox(config)
    # Support both keyword and positional arguments gracefully for Net::IMAP.new depending on Ruby/Net::IMAP version
    imap = Net::IMAP.new(config.imap_server, port: config.imap_port, ssl: config.ssl)

    imap.login(config.username, config.password)
    imap.select(config.mailbox)

    # Search for all UNSEEN emails
    message_ids = imap.search([ "UNSEEN" ])

    message_ids.each do |msg_id|
      # Fetch the raw RFC822 source of the message
      fetch_results = imap.fetch(msg_id, "RFC822")
      next if fetch_results.blank?

      raw_source = fetch_results.first.attr["RFC822"]
      next if raw_source.blank?

      # Process email
      PaymentEmailProcessorService.new(
        raw_source: raw_source,
        user:       config.user
      ).call

      # Mark email as Seen (read) in the IMAP server
      imap.store(msg_id, "+FLAGS", [ :Seen ])
    end

    # Update config metadata
    config.update!(last_polled_at: Time.current)
  ensure
    if imap
      imap.logout rescue nil
      imap.disconnect rescue nil
    end
  end
end
