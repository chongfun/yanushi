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
    client = GmailApiClient.new(config)
    messages = client.list_unread_messages
    messages.each do |msg_stub|
      raw_source = client.get_raw_message(msg_stub.id)
      next if raw_source.blank?

      # Process email
      PaymentEmailProcessorService.new(
        raw_source: raw_source,
        user:       config.user
      ).call

      # Mark email as read in Gmail
      client.mark_as_read(msg_stub.id)
    end

    # Update config metadata
    config.update!(last_polled_at: Time.current)
  end
end
