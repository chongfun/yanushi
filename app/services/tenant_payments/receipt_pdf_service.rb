module TenantPayments
  class ReceiptPdfService
    def self.call(tenant_payment:, view_context:)
      new(tenant_payment:, view_context:).call
    end

    def initialize(tenant_payment:, view_context:)
      @tenant_payment = tenant_payment
      @view_context = view_context
    end

    def call
      pdf = Prawn::Document.new
      pdf.text "Payment Receipt", size: 30, style: :bold
      pdf.move_down 20
      pdf.text "Payment Date: #{tenant_payment.payment_date}"
      pdf.text "Amount: #{view_context.number_to_currency(tenant_payment.amount)}"
      pdf.text "Method: #{tenant_payment.payment_method}"
      pdf.text "Transaction Number: #{tenant_payment.transaction_number}" if tenant_payment.transaction_number.present?
      pdf.text "Property: #{tenant_payment.lease.rental_property.address}"
      pdf.render
    end

    private

    attr_reader :tenant_payment, :view_context
  end
end
