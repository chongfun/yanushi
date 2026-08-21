class SourceDocumentsController < ApplicationController
  before_action :set_source_document, only: %i[download retry destroy]

  def new
    @source_document = authenticated_user.source_documents.build
  end

  def create
    result = SourceDocuments::UploadService.call(
      user: authenticated_user,
      pdf_param: params.dig(:source_document, :pdf_file)
    )
    if result.success?
      case result.value!.data[:upload_status]
      when :already_processed
        redirect_to imported_transactions_path, notice: "This document has already been processed successfully."
      when :already_processing
        redirect_to imported_transactions_path, notice: "This document is already currently being processed in the background."
      when :retry_required
        redirect_to imported_transactions_path, alert: "This document previously failed processing. Please click Retry in the Recent Uploads list."
      else
        redirect_to imported_transactions_path, notice: "Document uploaded successfully and is being processed in the background."
      end
    else
      redirect_to new_source_document_path, alert: result.failure.error
    end
  end

  def retry
    result = SourceDocuments::RetryService.call(user: authenticated_user, document: @source_document)
    if result.success?
      redirect_to imported_transactions_path, notice: "Document processing has been re-queued in the background."
    else
      redirect_to imported_transactions_path, alert: result.failure.error
    end
  end

  def download
    if @source_document.attachment_file.present?
      send_data @source_document.attachment_file,
                type: @source_document.attachment_content_type,
                disposition: "inline",
                filename: @source_document.attachment_filename
    else
      redirect_to imported_transactions_path, alert: "Document attachment data is missing."
    end
  end

  def destroy
    result = SourceDocuments::DestroyService.call(user: authenticated_user, document: @source_document)
    if result.success?
      redirect_to imported_transactions_path, notice: "Upload record was removed.", status: :see_other
    else
      redirect_to imported_transactions_path, alert: result.failure.error, status: :see_other
    end
  end

  private

    def set_source_document
      @source_document = authenticated_user.source_documents.find(params[:id])
    end
end
