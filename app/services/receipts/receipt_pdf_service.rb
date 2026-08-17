module Receipts
  class ReceiptPdfService
    def self.call(receipt:, view_context:)
      new(receipt: receipt, view_context: view_context).call
    end

    def initialize(receipt:, view_context:)
      @receipt = receipt
      @view_context = view_context
    end

    def call
      pdf = Prawn::Document.new
      pdf.text "Payment Receipt", size: 30, style: :bold

      if receipt.superseded?
        pdf.move_down 5
        pdf.text "[CORRECTED - REPLACED BY RECEIPT ##{receipt.superseded_by_id}]", size: 12, style: :bold, color: "CC0000"
      elsif receipt.voided?
        pdf.move_down 5
        pdf.text "[VOIDED - INACTIVE RECORD]", size: 12, style: :bold, color: "CC0000"
      elsif receipt.superseded_receipt.present?
        pdf.move_down 5
        pdf.text "[REPLACEMENT FOR RECEIPT ##{receipt.superseded_receipt.id}]", size: 12, style: :bold, color: "008800"
      end

      pdf.move_down 20
      pdf.text "Receipt ID: ##{receipt.id}"
      pdf.text "Payment Date: #{receipt.received_on.strftime('%B %d, %Y')}"
      pdf.text "Amount: #{view_context.number_to_currency(receipt.amount)}"
      pdf.text "Payer: #{receipt.payer_party&.display_name}"
      pdf.text "Method: #{receipt.payment_method.titleize}"
      pdf.text "Transaction / Reference: #{receipt.external_reference}" if receipt.external_reference.present?
      pdf.text "Memo: #{receipt.memo}" if receipt.memo.present?
      pdf.move_down 10
      pdf.text "Property: #{receipt.tenancy&.property&.address}"
      pdf.text "Unit: #{receipt.tenancy&.rentable_unit&.display_name}"
      pdf.text "Tenancy: ##{receipt.tenancy_id}"
      pdf.render
    end

    private

      attr_reader :receipt, :view_context
  end
end
