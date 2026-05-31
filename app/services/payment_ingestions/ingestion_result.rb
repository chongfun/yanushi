# app/services/payment_ingestions/ingestion_result.rb
require "dry/monads"
require "dry/struct"

module PaymentIngestions
  class IngestionResult < Dry::Struct
    extend Dry::Monads[:result]

    attribute? :payer_name, ServiceResultTypes::String.optional
    attribute? :payer_username, ServiceResultTypes::String.optional
    attribute? :amount, ServiceResultTypes::Any.optional
    attribute? :payment_date, ServiceResultTypes::Any.optional
    attribute? :payment_method, ServiceResultTypes::String.optional
    attribute? :transaction_number, ServiceResultTypes::String.optional
    attribute? :receipt_type, ServiceResultTypes::String.optional
    attribute? :raw_text, ServiceResultTypes::String.optional
    attribute? :error_message, ServiceResultTypes::String.optional

    def self.success(attributes)
      Success(new(attributes.merge(error_message: nil)))
    end

    def self.failure(attributes)
      Failure(new(attributes))
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
