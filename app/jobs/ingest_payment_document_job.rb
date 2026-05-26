class IngestPaymentDocumentJob < ApplicationJob
  queue_as :default

  def perform(payment_document_id, shard: "default")
    ShardedRecord.connected_to(role: :writing, shard: shard.to_sym) do
      payment_document = PaymentDocument.select(:id, :user_id, :attachment_filename, :attachment_content_type, :status, :error_message).find(payment_document_id)
      begin
        PaymentIngestions::Ingestion.new.call(
          user: payment_document.user,
          pdf_path_or_io: payment_document,
          source: "pdf_upload"
        )
        PaymentDocument.where(id: payment_document_id).update_all(status: :success)
      rescue => e
        PaymentDocument.where(id: payment_document_id).update_all(status: :failed, error_message: e.message)
        Rails.logger.error("Failed to ingest payment document #{payment_document_id}: #{e.message}\n#{e.backtrace.join("\n")}")
      end
    end
  end
end
