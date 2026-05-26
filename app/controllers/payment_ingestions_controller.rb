class PaymentIngestionsController < ApplicationController
  before_action :set_ingestion, only: %i[ show update destroy confirm download ]

  def index
    user = Current.session.user
    @reviewable_ingestions = user.payment_ingestions
                                 .includes(:tenant, lease: :rental_property)
                                 .reviewable
                                 .order(created_at: :desc)

    # Simple pagination for confirmed ingestions (History)
    @per_page = 20
    @page = [ params[:page].to_i, 1 ].max

    confirmed_scope = user.payment_ingestions
                          .includes(:tenant, lease: :rental_property)
                          .confirmed

    @total_confirmed_count = confirmed_scope.count
    @total_pages = (@total_confirmed_count.to_f / @per_page).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0

    @confirmed_ingestions = confirmed_scope.order(created_at: :desc)
                                           .limit(@per_page)
                                           .offset((@page - 1) * @per_page)

    @processing_documents = user.payment_documents
                                 .processing
                                 .select(:id, :user_id, :attachment_filename, :attachment_content_type, :status, :error_message, :created_at, :updated_at)
                                 .order(created_at: :desc)

    @failed_documents = user.payment_documents
                            .failed
                            .select(:id, :user_id, :attachment_filename, :attachment_content_type, :status, :error_message, :created_at, :updated_at)
                            .order(created_at: :desc)
  end

  def new
    @ingestion = Current.session.user.payment_ingestions.build
  end

  def create
    pdf_param = params.dig(:payment_ingestion, :pdf_file)
    if pdf_param.nil?
      redirect_to new_payment_ingestion_path, alert: "Please select a PDF file to upload."
      return
    end

    # Validate actual file content, not client-provided MIME type (which is spoofable)
    header = pdf_param.read(5)
    pdf_param.rewind
    unless header == "%PDF-"
      redirect_to new_payment_ingestion_path, alert: "Only PDF files are supported."
      return
    end

    if pdf_param.size > 10.megabytes
      redirect_to new_payment_ingestion_path, alert: "File size exceeds the 10MB limit."
      return
    end

    begin
      pdf_bytes = pdf_param.read
      filename = pdf_param.original_filename
      content_type = pdf_param.content_type

      payment_document = Current.session.user.payment_documents.create!(
        attachment_file: pdf_bytes,
        attachment_filename: filename,
        attachment_content_type: content_type,
        status: :processing
      )

      IngestPaymentDocumentJob.perform_later(payment_document.id, shard: Current.session.user.shard)

      redirect_to payment_ingestions_path, notice: "Document uploaded successfully and is being processed in the background."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to new_payment_ingestion_path, alert: "Upload failed: #{e.record.errors.full_messages.to_sentence}"
    rescue => e
      Rails.logger.error("Upload document failed: #{e.message}\n#{e.backtrace.join("\n")}")
      redirect_to new_payment_ingestion_path, alert: "Upload failed: An unexpected error occurred while processing the file."
    end
  end

  def show
    set_form_data
  end

  def update
    permitted_params = payment_ingestion_params

    if @ingestion.update(permitted_params)
      if @ingestion.confirmable? && (@ingestion.failed? || @ingestion.unmatched? || @ingestion.ambiguous?)
        @ingestion.update!(status: :matched)
      end

      redirect_to payment_ingestion_path(@ingestion), notice: "Ingestion record updated successfully."
    else
      set_form_data
      render :show, status: :unprocessable_entity
    end
  end

  def confirm
    create_alias = params[:create_alias] == "1"

    begin
      @ingestion.confirm!(create_alias: create_alias)
      redirect_to payment_ingestions_path, notice: "Payment confirmed and tenant payment created successfully."
    rescue PaymentIngestions::ConfirmationError => e
      redirect_to payment_ingestion_path(@ingestion), alert: e.message
    rescue => e
      Rails.logger.error("Confirm payment ingestion failed: #{e.message}\n#{e.backtrace.join("\n")}")
      redirect_to payment_ingestion_path(@ingestion), alert: "Failed to confirm payment: An unexpected error occurred."
    end
  end

  def download
    if @ingestion.attachment_attached?
      send_data @ingestion.payment_document.attachment_file,
                type: @ingestion.payment_document.attachment_content_type,
                disposition: "inline",
                filename: @ingestion.payment_document.attachment_filename
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
    @ingestion = Current.session.user.payment_ingestions.find(params[:id])
  end

  def payment_ingestion_params
    permitted_params = params.require(:payment_ingestion).permit(
      :tenant_id, :lease_id, :amount, :payment_date, :payment_method, :transaction_number
    )

    user = Current.session.user
    if permitted_params[:tenant_id].present?
      raise ActiveRecord::RecordNotFound unless user.tenants.where(id: permitted_params[:tenant_id]).exists?
    end
    if permitted_params[:lease_id].present?
      raise ActiveRecord::RecordNotFound unless user.leases.where(id: permitted_params[:lease_id]).exists?
    end
    permitted_params
  end

  def set_form_data
    user = Current.session.user
    @tenants = user.tenants.order(:name)
    @leases = Lease.joins(:tenants).where(tenants: { user_id: user.id }).includes(:rental_property).distinct

    # Preload and group in Ruby memory to avoid N+1 queries
    @tenant_leases_map = Hash.new { |h, k| h[k] = [] }
    LeaseTenant.joins(:tenant).where(tenants: { user_id: user.id }).pluck(:tenant_id, :lease_id).each do |tenant_id, lease_id|
      @tenant_leases_map[tenant_id] << lease_id
    end

    @lease_tenants_map = Hash.new { |h, k| h[k] = [] }
    LeaseTenant.joins(lease: :rental_property).where(rental_properties: { user_id: user.id }).pluck(:lease_id, :tenant_id).each do |lease_id, tenant_id|
      @lease_tenants_map[lease_id] << tenant_id
    end
  end
end
