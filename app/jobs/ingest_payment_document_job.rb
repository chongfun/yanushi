class IngestPaymentDocumentJob < ApplicationJob
  queue_as :default

  def perform(payment_document_id)
    payment_document = PaymentDocument.find(payment_document_id)
    begin
      PaymentIngestions::Ingestion.new.call(
        user: payment_document.user,
        pdf_path_or_io: payment_document,
        source: "pdf_upload"
      )
      payment_document.update!(status: :success)
    rescue => e
      payment_document.update!(status: :failed, error_message: e.message)
      Rails.logger.error("Failed to ingest payment document #{payment_document_id}: #{e.message}\n#{e.backtrace.join("\n")}")
    end
  end
end
