class IngestSourceDocumentJob < ApplicationJob
  queue_as :default

  def perform(source_document_id)
    source_document = SourceDocument.find_by(id: source_document_id)
    return unless source_document

    begin
      ImportedTransactions::IngestionService.call(
        user: source_document.user,
        pdf_path_or_io: source_document,
        source: "pdf_upload"
      )
      ImportedTransactions::InboxBroadcastService.call(user: source_document.user, document: source_document)
    rescue => e
      begin
        source_document.with_lock do
          source_document.reload
          unless source_document.success?
            source_document.update_columns(status: "failed", error_message: e.message)
            source_document.user.increment_inbox_revision!
          end
        end
        ImportedTransactions::InboxBroadcastService.call(user: source_document.user, document: source_document)
      rescue ActiveRecord::RecordNotFound
        # Source document was concurrently deleted
      rescue => lock_err
        Rails.logger.error("Failed to update status for source document #{source_document_id}: #{lock_err.message}")
      end
      Rails.logger.error("Failed to ingest source document #{source_document_id}: #{e.message}\n#{e.backtrace.join("\n")}")
    end
  end
end
