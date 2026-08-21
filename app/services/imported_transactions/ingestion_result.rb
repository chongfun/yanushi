require "dry/monads"
require "dry/struct"

module ImportedTransactions
  class IngestionResult < Dry::Struct
    extend Dry::Monads[:result]

    attribute? :document_type, ServiceResultTypes::String.optional
    attribute? :amount_cents, ServiceResultTypes::Integer.optional
    attribute? :occurred_on, ServiceResultTypes::Any.optional
    attribute? :external_reference, ServiceResultTypes::String.optional
    attribute? :payment_method, ServiceResultTypes::String.optional
    attribute? :payer_name, ServiceResultTypes::String.optional
    attribute? :payer_username, ServiceResultTypes::String.optional
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
        document_type: document_type,
        amount_cents: amount_cents,
        occurred_on: occurred_on,
        external_reference: external_reference,
        payment_method: payment_method,
        payer_name: payer_name,
        payer_username: payer_username,
        raw_text: raw_text,
        error_message: error_message
      }
    end
  end
end
