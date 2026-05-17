class PaymentEmailParserService
  class UnknownProviderError < StandardError; end

  # Chase Bank Zelle notification patterns (matching real downloaded .eml files)
  CHASE_ZELLE_PATTERNS = {
    amount: /Amount\s+\$([\d,]+\.\d{2})/i,
    sender: /(.+?)\s+sent\s+you\s+money/i,
    date:   /Sent\s+on\s+(\w+\s+\d{1,2},\s*\d{4})/i,
    confirmation: /Transaction\s+number\s+(\d+)/i
  }.freeze

  # Venmo notification patterns (matching real downloaded .eml files)
  VENMO_PATTERNS = {
    # Amount is matched either in body (e.g. "+ $1,000.00") or in subject ("samantha sanchez paid you $1,000.00")
    amount: /(?:\+\s+\$|paid\s+you\s+\$)([\d,]+\.\d{2})/i,
    # Sender is matched in either subject or body before "paid you"
    sender: /(.+?)\s+paid\s+you/i,
    date:   /([A-Z][a-z]{2}\s+\d{1,2},\s*\d{4})/i,
    confirmation: /Payment\s+ID:\s*(\d+)/i
  }.freeze

  PROVIDER_PATTERNS = {
    "zelle" => CHASE_ZELLE_PATTERNS,
    "venmo" => VENMO_PATTERNS
  }.freeze

  def initialize(subject:, body:)
    @subject = subject.to_s
    @body = body.to_s
  end

  def parse
    provider = detect_provider
    patterns = PROVIDER_PATTERNS[provider]

    {
      provider:       provider,
      sender_name:    extract(patterns[:sender]),
      amount:         extract_amount(patterns[:amount]),
      payment_date:   extract_date(patterns[:date]),
      transaction_id: extract(patterns[:confirmation])
    }
  end

  private

  def detect_provider
    combined = "#{@subject} #{@body}"
    if combined.match?(/venmo/i)
      "venmo"
    elsif combined.match?(/zelle/i)
      "zelle"
    else
      raise UnknownProviderError, "Could not detect payment provider from email subject or body"
    end
  end

  def extract(pattern)
    # Check body first, then subject
    match = @body.match(pattern) || @subject.match(pattern)
    match ? match[1]&.strip : nil
  end

  def extract_amount(pattern)
    match = @body.match(pattern) || @subject.match(pattern)
    match ? match[1].gsub(/,/, "").to_d : nil
  end

  def extract_date(pattern)
    match = @body.match(pattern) || @subject.match(pattern)
    match ? Date.parse(match[1]) : nil
  rescue Date::Error
    nil
  end
end
