module Receipts
  class PostService
    def self.call(receipt:)
      new(receipt: receipt).call
    end

    def initialize(receipt:)
      @receipt = receipt
    end

    def call
      unless receipt.is_a?(Receipt) && receipt.persisted? && !receipt.destroyed?
        return ServiceResult.failure(error: "Receipt must be a persisted Receipt record", code: :invalid_source)
      end

      if receipt.voided?
        return ServiceResult.failure(error: "Cannot post a voided receipt", code: :invalid_state)
      end

      postings = [
        Accounting::PostingSpec.new(
          account_key: "cash",
          amount_cents: receipt.amount_cents,
          tenancy: receipt.tenancy,
          party: receipt.payer_party
        ),
        Accounting::PostingSpec.new(
          account_key: "tenant_receivable",
          amount_cents: -receipt.amount_cents,
          tenancy: receipt.tenancy,
          party: receipt.payer_party
        )
      ]

      description = default_description

      Accounting::PostEntryService.call(
        source: receipt,
        event_type: "receipt_posted",
        occurred_on: receipt.received_on,
        postings: postings,
        description: description
      )
    end

    private

      attr_reader :receipt

      def default_description
        "Payment received - #{receipt.payment_method.titleize}"
      end
  end
end
