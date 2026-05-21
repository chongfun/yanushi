# app/services/payment_receipts/ingestion_result.rb
module PaymentIngestions
  class IngestionResult
    attr_accessor :payer_name, :payer_username, :amount, :payment_date,
                  :payment_method, :transaction_number, :receipt_type,
                  :raw_text, :error_message, :success

    def initialize(attrs = {})
      attrs.each { |k, v| send(:"#{k}=", v) }
    end

    def success?
      !!success && error_message.nil?
    end

    def to_h
      {
        payer_name: payer_name,
        payer_username: payer_username,
        amount: amount,
        payment_date: payment_date,
        payment_method: payment_method,
        transaction_number: transaction_number,
        receipt_type: receipt_type,
        raw_text: raw_text,
        error_message: error_message
      }
    end
  end
end
