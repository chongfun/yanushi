# app/controllers/payment_receipt_ingestions_controller.rb
class PaymentReceiptIngestionsController < ApplicationController
  before_action :set_ingestion, only: %i[ show update destroy confirm download ]

  def index
    user = Current.session.user
    @reviewable_ingestions = user.payment_receipt_ingestions
                                 .includes(:tenant, lease: :rental_property)
                                 .reviewable
                                 .order(created_at: :desc)

    @confirmed_ingestions = user.payment_receipt_ingestions
                                .includes(:tenant, lease: :rental_property)
                                .confirmed
                                .order(created_at: :desc)
  end

  def new
    @ingestion = Current.session.user.payment_receipt_ingestions.build
  end

  def create
    pdf_param = params.dig(:payment_receipt_ingestion, :pdf_file)
    if pdf_param.nil?
      redirect_to new_payment_receipt_ingestion_path, alert: "Please select a PDF file to upload."
      return
    end

    begin
      @ingestion = PaymentReceipts::Ingestion.new.call(
        user: Current.session.user,
        pdf_path_or_io: pdf_param,
        source: "pdf_upload"
      )

      if @ingestion.persisted?
        if @ingestion.failed?
          redirect_to payment_receipt_ingestion_path(@ingestion), alert: "Parsing failed. Please manually fill in the details."
        else
          redirect_to payment_receipt_ingestion_path(@ingestion), notice: "Receipt uploaded and parsed successfully."
        end
      else
        error_msg = @ingestion.errors.full_messages.to_sentence.presence || "Could not save ingestion record."
        redirect_to new_payment_receipt_ingestion_path, alert: error_msg
      end
    rescue PaymentReceipts::ParsingError => e
      redirect_to new_payment_receipt_ingestion_path, alert: "Parsing failed: #{e.message}"
    end
  end

  def show
    user = Current.session.user
    @tenants = user.tenants.order(:name)
    @leases = if @ingestion.tenant.present?
      @ingestion.tenant.leases.includes(:rental_property)
    else
      Lease.joins(:tenants).where(tenants: { user_id: user.id }).includes(:rental_property).distinct
    end
  end

  def update
    # Update ingestion parameters
    permitted_params = params.require(:payment_receipt_ingestion).permit(
      :tenant_id, :lease_id, :amount, :payment_date, :payment_method, :transaction_number
    )

    if @ingestion.update(permitted_params)
      # If updated manually and required fields are set, auto-transition from failed/unmatched to matched
      if @ingestion.confirmable? && (@ingestion.failed? || @ingestion.unmatched? || @ingestion.ambiguous?)
        @ingestion.update!(status: :matched)
      end

      redirect_to payment_receipt_ingestion_path(@ingestion), notice: "Ingestion record updated successfully."
    else
      user = Current.session.user
      @tenants = user.tenants.order(:name)
      @leases = @ingestion.tenant.present? ? @ingestion.tenant.leases.includes(:rental_property) : Lease.joins(:tenants).where(tenants: { user_id: user.id }).includes(:rental_property).distinct
      render :show, status: :unprocessable_entity
    end
  end

  def confirm
    create_alias = params[:create_alias] == "1"

    begin
      @ingestion.confirm!(create_alias: create_alias)
      redirect_to payment_receipt_ingestions_path, notice: "Payment confirmed and tenant payment created successfully."
    rescue PaymentReceipts::ConfirmationError => e
      redirect_to payment_receipt_ingestion_path(@ingestion), alert: e.message
    rescue => e
      redirect_to payment_receipt_ingestion_path(@ingestion), alert: "Failed to confirm payment: #{e.message}"
    end
  end

  def download
    if @ingestion.attachment_attached?
      send_data @ingestion.attachment_file,
                type: @ingestion.attachment_content_type,
                disposition: "inline",
                filename: @ingestion.attachment_filename
    else
      redirect_to payment_receipt_ingestion_path(@ingestion), alert: "Receipt attachment data is missing."
    end
  end

  def destroy
    @ingestion.destroy!
    redirect_to payment_receipt_ingestions_path, notice: "Ingestion record was deleted.", status: :see_other
  end

  private

  def set_ingestion
    @ingestion = Current.session.user.payment_receipt_ingestions.find(params[:id])
  end
end
