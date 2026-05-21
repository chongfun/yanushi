class PaymentIngestionsController < ApplicationController
  before_action :set_ingestion, only: %i[ show update destroy confirm download ]

  def index
    user = Current.session.user
    @reviewable_ingestions = user.payment_ingestions
                                 .includes(:tenant, lease: :rental_property)
                                 .reviewable
                                 .order(created_at: :desc)

    @confirmed_ingestions = user.payment_ingestions
                                .includes(:tenant, lease: :rental_property)
                                .confirmed
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

    begin
      result = PaymentIngestions::Ingestion.new.call(
        user: Current.session.user,
        pdf_path_or_io: pdf_param,
        source: "pdf_upload"
      )

      if result.is_a?(Array)
        saved_count = result.select(&:persisted?).count
        if saved_count > 0
          redirect_to payment_ingestions_path, notice: "Bank statement parsed successfully. Found #{saved_count} matching tenant payment transaction(s)."
        else
          redirect_to payment_ingestions_path, alert: "Bank statement parsed, but no matching tenant transactions were found."
        end
      else
        @ingestion = result
        if @ingestion.persisted?
          if @ingestion.failed?
            redirect_to payment_ingestion_path(@ingestion), alert: "Parsing failed. Please manually fill in the details."
          else
            redirect_to payment_ingestion_path(@ingestion), notice: "Receipt uploaded and parsed successfully."
          end
        else
          error_msg = @ingestion.errors.full_messages.to_sentence.presence || "Could not save ingestion record."
          redirect_to new_payment_ingestion_path, alert: error_msg
        end
      end
    rescue PaymentIngestions::ParsingError => e
      redirect_to new_payment_ingestion_path, alert: "Parsing failed: #{e.message}"
    end
  end

  def show
    user = Current.session.user
    @tenants = user.tenants.order(:name)
    @leases = Lease.joins(:tenants).where(tenants: { user_id: user.id }).includes(:rental_property).distinct

    # Build maps for Stimulus dynamic filtering
    @tenant_leases_map = {}
    @tenants.each do |tenant|
      @tenant_leases_map[tenant.id] = tenant.leases.pluck(:id)
    end

    @lease_tenants_map = {}
    @leases.each do |lease|
      @lease_tenants_map[lease.id] = lease.tenants.pluck(:id)
    end
  end

  def update
    permitted_params = params.require(:payment_ingestion).permit(
      :tenant_id, :lease_id, :amount, :payment_date, :payment_method, :transaction_number
    )

    if @ingestion.update(permitted_params)
      if @ingestion.confirmable? && (@ingestion.failed? || @ingestion.unmatched? || @ingestion.ambiguous?)
        @ingestion.update!(status: :matched)
      end

      redirect_to payment_ingestion_path(@ingestion), notice: "Ingestion record updated successfully."
    else
      user = Current.session.user
      @tenants = user.tenants.order(:name)
      @leases = Lease.joins(:tenants).where(tenants: { user_id: user.id }).includes(:rental_property).distinct

      @tenant_leases_map = {}
      @tenants.each do |tenant|
        @tenant_leases_map[tenant.id] = tenant.leases.pluck(:id)
      end

      @lease_tenants_map = {}
      @leases.each do |lease|
        @lease_tenants_map[lease.id] = lease.tenants.pluck(:id)
      end

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
      redirect_to payment_ingestion_path(@ingestion), alert: "Failed to confirm payment: #{e.message}"
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
end
