class ReceiptsController < ApplicationController
  before_action :set_tenancy, only: %i[new create]
  before_action :set_receipt, only: %i[show correction correct void]

  def index
    @receipts = authenticated_user.receipts
                                  .includes(:payer_party, tenancy: { rentable_unit: :property })
                                  .order(received_on: :desc, created_at: :desc)
  end

  def show
    respond_to do |format|
      format.html
      format.pdf do
        pdf_data = Receipts::ReceiptPdfService.call(receipt: @receipt, view_context: view_context)
        send_data pdf_data,
                  filename: "receipt-#{@receipt.id}.pdf",
                  type: "application/pdf",
                  disposition: "inline"
      end
    end
  end

  def new
    @receipt = Receipt.new(
      tenancy: @tenancy,
      received_on: Date.current
    )

    if (t = @tenancy)
      balance = t.current_balance
      @receipt.amount = balance > 0 ? balance : nil
      active_tenants = t.tenancy_parties.active.where(role: :tenant).map(&:party).compact
      @receipt.payer_party = active_tenants.first if active_tenants.size == 1
    end

    load_form_collections
  end

  def create
    if (t = @tenancy)
      if receipt_params[:tenancy_id].present? && receipt_params[:tenancy_id].to_s != t.id.to_s
        @receipt = Receipt.new(receipt_params)
        @receipt.tenancy = t
        flash.now[:alert] = "Submitted tenancy does not match route tenancy"
        load_form_collections
        return respond_to do |format|
          format.html { render :new, status: :unprocessable_content }
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace("new_receipt_form",
                                                     partial: "receipts/modal_form",
                                                     locals: { receipt: @receipt, tenancy: @tenancy }),
                   status: :unprocessable_content
          end
        end
      end
      target_tenancy = t
    else
      if receipt_params[:tenancy_id].blank?
        @receipt = Receipt.new(receipt_params)
        flash.now[:alert] = "Tenancy is required"
        load_form_collections
        return respond_to do |format|
          format.html { render :new, status: :unprocessable_content }
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace("new_receipt_form",
                                                     partial: "receipts/modal_form",
                                                     locals: { receipt: @receipt, tenancy: @tenancy }),
                   status: :unprocessable_content
          end
        end
      end

      target_tenancy = authenticated_user.tenancies.find_by(id: receipt_params[:tenancy_id])
      unless target_tenancy
        @receipt = Receipt.new(receipt_params)
        flash.now[:alert] = "Tenancy was not found"
        load_form_collections
        return respond_to do |format|
          format.html { render :new, status: :unprocessable_content }
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace("new_receipt_form",
                                                     partial: "receipts/modal_form",
                                                     locals: { receipt: @receipt, tenancy: @tenancy }),
                   status: :unprocessable_content
          end
        end
      end
    end

    target_payer = if receipt_params[:payer_party_id].present?
      authenticated_user.parties.find_by(id: receipt_params[:payer_party_id])
    end

    if receipt_params[:payer_party_id].present? && target_payer.nil?
      @receipt = Receipt.new(receipt_params)
      @receipt.tenancy = target_tenancy
      flash.now[:alert] = "Payer party was not found"
      load_form_collections
      return respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace("new_receipt_form",
                                                   partial: "receipts/modal_form",
                                                   locals: { receipt: @receipt, tenancy: @tenancy }),
                 status: :unprocessable_content
        end
      end
    end

    result = Receipts::CreateService.call(
      tenancy: target_tenancy,
      payer_party: target_payer,
      amount: receipt_params[:amount],
      received_on: receipt_params[:received_on],
      payment_method: receipt_params[:payment_method],
      external_reference: receipt_params[:external_reference],
      memo: receipt_params[:memo]
    )

    if result.success?
      created_receipt = result.value!.data[:receipt]
      respond_to do |format|
        format.html { redirect_to receipt_path(created_receipt), notice: "Payment recorded successfully." }
        format.turbo_stream { redirect_to receipt_path(created_receipt), notice: "Payment recorded successfully." }
      end
    else
      @receipt = Receipt.new(receipt_params)
      @receipt.tenancy = target_tenancy
      @receipt.payer_party = target_payer
      flash.now[:alert] = result.failure.error
      load_form_collections
      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace("new_receipt_form",
                                                   partial: "receipts/modal_form",
                                                   locals: { receipt: @receipt, tenancy: @tenancy }),
                 status: :unprocessable_content
        end
      end
    end
  end

  def correction
    @replacement_receipt = Receipt.new(
      tenancy: @receipt.tenancy,
      payer_party: @receipt.payer_party,
      amount_cents: @receipt.amount_cents,
      received_on: @receipt.received_on,
      payment_method: @receipt.payment_method,
      external_reference: @receipt.external_reference,
      memo: @receipt.memo
    )
    load_form_collections
  end

  def correct
    if receipt_params[:tenancy_id].present?
      target_tenancy = authenticated_user.tenancies.find_by(id: receipt_params[:tenancy_id])
      unless target_tenancy
        @replacement_receipt = Receipt.new(receipt_params)
        flash.now[:alert] = "Tenancy was not found"
        load_form_collections
        return render :correction, status: :unprocessable_content
      end
    else
      target_tenancy = @receipt.tenancy
    end

    if receipt_params[:payer_party_id].present?
      target_payer = authenticated_user.parties.find_by(id: receipt_params[:payer_party_id])
      unless target_payer
        @replacement_receipt = Receipt.new(receipt_params)
        @replacement_receipt.tenancy = target_tenancy
        flash.now[:alert] = "Payer party was not found"
        load_form_collections
        return render :correction, status: :unprocessable_content
      end
    else
      target_payer = @receipt.payer_party
    end

    result = Receipts::CorrectService.call(
      receipt: @receipt,
      tenancy: target_tenancy,
      payer_party: target_payer,
      amount: receipt_params[:amount],
      received_on: receipt_params[:received_on],
      payment_method: receipt_params[:payment_method],
      external_reference: receipt_params[:external_reference],
      memo: receipt_params[:memo]
    )

    if result.success?
      replacement = result.value!.data[:receipt]
      redirect_to receipt_path(replacement), notice: "Payment corrected successfully. Original payment ##{@receipt.id} has been reversed."
    else
      @replacement_receipt = Receipt.new(receipt_params)
      @replacement_receipt.tenancy = target_tenancy
      @replacement_receipt.payer_party = target_payer
      flash.now[:alert] = result.failure.error
      load_form_collections
      render :correction, status: :unprocessable_content
    end
  end

  def void
    result = Receipts::VoidService.call(
      receipt: @receipt,
      reason: params[:reason]
    )

    if result.success?
      redirect_to receipt_path(@receipt), notice: "Payment has been voided and accounting entries reversed."
    else
      redirect_to receipt_path(@receipt), alert: result.failure.error
    end
  end

  private

    def set_tenancy
      @tenancy = authenticated_user.tenancies.find(params[:tenancy_id]) if params[:tenancy_id]
    end

    def set_receipt
      @receipt = authenticated_user.receipts.find(params.expect(:id))
    end

    def receipt_params
      receipt_p = params[:receipt]
      if receipt_p.is_a?(ActionController::Parameters)
        receipt_p.permit(
          :tenancy_id,
          :payer_party_id,
          :amount,
          :received_on,
          :payment_method,
          :external_reference,
          :memo
        )
      else
        ActionController::Parameters.new.permit(
          :tenancy_id,
          :payer_party_id,
          :amount,
          :received_on,
          :payment_method,
          :external_reference,
          :memo
        )
      end
    end

    def load_form_collections
      @tenancies = authenticated_user.tenancies.includes(:parties, rentable_unit: :property)
      @parties = authenticated_user.parties.order(:display_name)
    end
end
