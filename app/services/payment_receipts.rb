# app/services/payment_receipts.rb
module PaymentReceipts
  class Error < StandardError; end
  class ParsingError < Error; end
  class ResolutionError < Error; end
  class ConfirmationError < Error; end
end
