class PaymentIngestionsController < ApplicationController
  before_action :set_ingestion, only: %i[ show update destroy confirm download ]

  def index
    user = authenticated_user
    result = PaymentIngestions::IndexQuery.new(user: user).call(page: params[:page])

    @reviewable_ingestions = result.reviewable_ingestions
    @per_page = result.per_page
    @page = result.page
    @total_confirmed_count = result.total_confirmed_count
    @total_pages = result.total_pages
    @confirmed_ingestions = result.confirmed_ingestions
    @processing_documents = result.processing_documents
    @failed_documents = result.failed_documents
  end

  def new
    @ingestion = authenticated_user.payment_ingestions.build
  end

  def create
    result = PaymentIngestions::UploadService.call(user: authenticated_user, pdf_param: params.dig(:payment_ingestion, :pdf_file))
    if result.success?
      redirect_to payment_ingestions_path, notice: "Document uploaded successfully and is being processed in the background."
    else
      redirect_to new_payment_ingestion_path, alert: result.failure.error
    end
  end

  def show
    set_form_data
  end

  def update
    result = PaymentIngestions::UpdateService.call(user: authenticated_user, ingestion: @ingestion, params: payment_ingestion_params)
    if result.success?
      redirect_to payment_ingestion_path(@ingestion), notice: "Ingestion record updated successfully."
    else
      set_form_data
      render :show, status: :unprocessable_content
    end
  end

  def confirm
    create_alias = params[:create_alias] == "1"

    begin
      result = PaymentIngestions::ConfirmService.call(user: authenticated_user, ingestion: @ingestion, create_alias: create_alias)
      if result.success?
        redirect_to payment_ingestions_path, notice: "Payment confirmed and tenant payment created successfully."
      else
        redirect_to payment_ingestion_path(@ingestion), alert: result.failure.error
      end
    rescue => e
      Rails.logger.error("Confirm payment ingestion failed: #{e.message}\n#{e.backtrace.join("\n")}")
      redirect_to payment_ingestion_path(@ingestion), alert: "Failed to confirm payment: An unexpected error occurred."
    end
  end

  def download
    if @ingestion.attachment_attached? && (doc = @ingestion.payment_document)
      send_data doc.attachment_file,
                type: doc.attachment_content_type,
                disposition: "inline",
                filename: doc.attachment_filename
    else
      redirect_to payment_ingestion_path(@ingestion), alert: "Receipt attachment data is missing."
    end
  end

  def destroy
    @ingestion.destroy!
    redirect_to payment_ingestions_path, notice: "Ingestion record was deleted.", status: :see_other
  end

  private

  def set_ingestion
    @ingestion = authenticated_user.payment_ingestions.find(params[:id])
  end

  def payment_ingestion_params
    permitted_params = params.require(:payment_ingestion).permit(
      :tenant_id, :lease_id, :amount, :payment_date, :payment_method, :transaction_number
    )

    user = authenticated_user
    if permitted_params[:tenant_id].present?
      raise ActiveRecord::RecordNotFound unless user.tenants.where(id: permitted_params[:tenant_id]).exists?
    end
    if permitted_params[:lease_id].present?
      raise ActiveRecord::RecordNotFound unless user.leases.where(id: permitted_params[:lease_id]).exists?
    end
    permitted_params
  end

  def set_form_data
    result = PaymentIngestions::FormDataQuery.new(user: authenticated_user).call
    @tenants = result.tenants
    @leases = result.leases
    @tenant_leases_map = result.tenant_leases_map
    @lease_tenants_map = result.lease_tenants_map
  end
end
