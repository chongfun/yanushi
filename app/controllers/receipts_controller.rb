class ReceiptsController < ApplicationController
  before_action :set_tenancy, only: %i[new create]
  before_action :set_receipt, only: %i[show correction correct void]

  def index
    page = [ params[:page].to_i, 1 ].max
    @per_page = 25
    scope = authenticated_user.receipts
                              .includes(:payer_party, :superseded_by, :superseded_receipt, :imported_transaction, tenancy: [ :property, :rentable_unit ])
                              .order(received_on: :desc, created_at: :desc)
    @total_count = scope.count
    @total_pages = @total_count.zero? ? 0 : (@total_count.to_f / @per_page).ceil
    @page = @total_pages > 0 ? [ page, @total_pages ].min : page
    @receipts = scope.limit(@per_page).offset((@page - 1) * @per_page)
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

    load_form_collections

    if (t = @tenancy)
      balance_cents = @balance_cents.to_i
      @receipt.amount = balance_cents > 0 ? format("%.2f", balance_cents / 100.0) : nil
      primary_tenants = t.primary_tenant_parties
      @receipt.payer_party = primary_tenants.first if primary_tenants.size == 1
    end
  end

  def create
    # Resolve payer through current user scope
    target_payer = if receipt_params[:payer_party_id].present?
      authenticated_user.parties.find_by(id: receipt_params[:payer_party_id])
    end

    if (t = @tenancy)
      if receipt_params[:tenancy_id].present? && receipt_params[:tenancy_id].to_s != t.id.to_s
        @receipt = Receipt.new(receipt_params.except(:tenancy_id, :payer_party_id))
        @receipt.tenancy = t
        @receipt.payer_party = target_payer
        @receipt.errors.add(:tenancy_id, "Submitted tenancy does not match route tenancy")
        flash.now[:alert] = "Submitted tenancy does not match route tenancy"
        return render_receipt_failure
      end
      target_tenancy = t
    else
      if receipt_params[:tenancy_id].blank?
        @receipt = Receipt.new(receipt_params.except(:tenancy_id, :payer_party_id))
        @receipt.tenancy = nil
        @receipt.payer_party = target_payer
        @receipt.errors.add(:tenancy_id, "Tenancy is required")
        flash.now[:alert] = "Tenancy is required"
        return render_receipt_failure
      end

      target_tenancy = authenticated_user.tenancies.find_by(id: receipt_params[:tenancy_id])
      unless target_tenancy
        @receipt = Receipt.new(receipt_params.except(:tenancy_id, :payer_party_id))
        @receipt.tenancy = nil
        @receipt.payer_party = target_payer
        @receipt.errors.add(:tenancy_id, "Tenancy was not found")
        flash.now[:alert] = "Tenancy was not found"
        return render_receipt_failure
      end
    end

    if receipt_params[:payer_party_id].present? && target_payer.nil?
      @receipt = Receipt.new(receipt_params.except(:tenancy_id, :payer_party_id))
      @receipt.tenancy = target_tenancy
      @receipt.payer_party = nil
      @receipt.errors.add(:payer_party_id, "Payer party was not found")
      flash.now[:alert] = "Payer party was not found"
      return render_receipt_failure
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
        format.html do
          redirect_path = @tenancy ? tenancy_path(@tenancy) : receipt_path(created_receipt)
          redirect_to redirect_path, notice: "Payment recorded successfully.", status: :see_other
        end
        format.turbo_stream do
          if (t = @tenancy)
            @balance_cents = Accounting::TenancyBalanceQuery.balance_cents_as_of(tenancy: t, as_of: Date.current)
            @recent_activity_rows = Accounting::RecentTenantReceivableActivityQuery.call(tenancy: t)
            render "receipts/create", formats: [ :turbo_stream ]
          else
            redirect_to receipt_path(created_receipt), notice: "Payment recorded successfully.", status: :see_other
          end
        end
      end
    else
      @receipt = if result.failure.data && result.failure.data[:receipt]
        result.failure.data[:receipt]
      else
        Receipt.new(receipt_params.except(:tenancy_id, :payer_party_id)).tap do |r|
          r.tenancy = target_tenancy
          r.payer_party = target_payer
        end
      end
      if @receipt.errors.empty?
        error_msg = result.failure.error.to_s
        err_lower = error_msg.downcase
        if err_lower.include?("amount")
          @receipt.errors.add(:amount, error_msg)
        elsif err_lower.include?("payer")
          @receipt.errors.add(:payer_party_id, error_msg)
        elsif err_lower.include?("received on") || err_lower.include?("date")
          @receipt.errors.add(:received_on, error_msg)
        elsif err_lower.include?("payment method")
          @receipt.errors.add(:payment_method, error_msg)
        elsif err_lower.include?("reference")
          @receipt.errors.add(:external_reference, error_msg)
        else
          @receipt.errors.add(:base, error_msg)
        end
      end
      flash.now[:alert] = result.failure.error
      render_receipt_failure
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
    # Build replacement without untrusted association IDs
    safe_params = receipt_params.except(:tenancy_id, :payer_party_id)
    @replacement_receipt = Receipt.new(safe_params)
    @replacement_receipt.user = authenticated_user

    # Preserve current tenancy if omitted
    target_tenancy = if receipt_params.key?(:tenancy_id)
      if receipt_params[:tenancy_id].present?
        authenticated_user.tenancies.find_by(id: receipt_params[:tenancy_id])
      end
    else
      @receipt.tenancy
    end
    @replacement_receipt.tenancy = target_tenancy

    # Preserve current payer if omitted
    target_payer = if receipt_params.key?(:payer_party_id)
      if receipt_params[:payer_party_id].present?
        authenticated_user.parties.find_by(id: receipt_params[:payer_party_id])
      end
    else
      @receipt.payer_party
    end
    @replacement_receipt.payer_party = target_payer

    # Default omitted fields to current values for validation
    @replacement_receipt.amount_cents = @receipt.amount_cents unless receipt_params.key?(:amount)
    @replacement_receipt.received_on = @receipt.received_on unless receipt_params.key?(:received_on)
    @replacement_receipt.payment_method = @receipt.payment_method unless receipt_params.key?(:payment_method)

    @replacement_receipt.valid?

    # Retaining existing reference is valid as original will be voided
    if @replacement_receipt.external_reference == @receipt.external_reference &&
       @replacement_receipt.payment_method == @receipt.payment_method
      @replacement_receipt.errors.delete(:external_reference)
    end

    if receipt_params.key?(:tenancy_id) && receipt_params[:tenancy_id].present? && target_tenancy.nil?
      @replacement_receipt.errors.delete(:tenancy)
      @replacement_receipt.errors.add(:tenancy_id, "Tenancy was not found")
    elsif receipt_params.key?(:tenancy_id) && receipt_params[:tenancy_id].blank?
      @replacement_receipt.errors.delete(:tenancy)
      @replacement_receipt.errors.add(:tenancy_id, "must be selected")
    end

    if receipt_params.key?(:payer_party_id) && receipt_params[:payer_party_id].present? && target_payer.nil?
      @replacement_receipt.errors.delete(:payer_party)
      @replacement_receipt.errors.add(:payer_party_id, "Payer party was not found")
    elsif receipt_params.key?(:payer_party_id) && receipt_params[:payer_party_id].blank?
      @replacement_receipt.errors.delete(:payer_party)
      @replacement_receipt.errors.add(:payer_party_id, "must be selected")
    end

    # Reject submitted blank required fields
    if receipt_params.key?(:amount) && receipt_params[:amount].blank?
      @replacement_receipt.errors.add(:amount, "can't be blank")
    end

    if receipt_params.key?(:received_on) && receipt_params[:received_on].blank?
      @replacement_receipt.errors.add(:received_on, "can't be blank")
    end

    if receipt_params.key?(:payment_method) && receipt_params[:payment_method].blank?
      @replacement_receipt.errors.add(:payment_method, "can't be blank")
    end

    if @replacement_expense&.errors&.any? || @replacement_receipt.errors.any?
      flash.now[:alert] = "Please fix the errors below."
      load_form_collections
      return render :correction, status: :unprocessable_content
    end

    result = Receipts::CorrectService.call(
      receipt: @receipt,
      tenancy: target_tenancy,
      payer_party: target_payer,
      amount: receipt_params[:amount],
      amount_cents: receipt_params.key?(:amount) ? nil : @receipt.amount_cents,
      received_on: receipt_params[:received_on] || @receipt.received_on,
      payment_method: receipt_params[:payment_method] || @receipt.payment_method,
      external_reference: receipt_params.key?(:external_reference) ? receipt_params[:external_reference] : @receipt.external_reference,
      memo: receipt_params.key?(:memo) ? receipt_params[:memo] : @receipt.memo
    )

    if result.success?
      replacement = result.value!.data[:receipt]
      redirect_to receipt_path(replacement), notice: "Payment corrected successfully. Original payment ##{@receipt.id} has been reversed.", status: :see_other
    else
      @replacement_receipt.valid?
      error_msg = result.failure.error.to_s
      err_lower = error_msg.downcase
      if err_lower.include?("amount")
        @replacement_receipt.errors.add(:amount, error_msg)
      elsif err_lower.include?("method")
        @replacement_receipt.errors.add(:payment_method, error_msg)
      elsif err_lower.include?("date") || err_lower.include?("received")
        @replacement_receipt.errors.add(:received_on, error_msg)
      elsif err_lower.include?("tenancy")
        @replacement_receipt.errors.add(:tenancy_id, error_msg)
      elsif err_lower.include?("payer") || err_lower.include?("party")
        @replacement_receipt.errors.add(:payer_party_id, error_msg)
      elsif err_lower.include?("reference")
        @replacement_receipt.errors.add(:external_reference, error_msg)
      else
        @replacement_receipt.errors.add(:base, error_msg)
      end
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
      redirect_to receipt_path(@receipt), notice: "Payment has been voided and accounting entries reversed.", status: :see_other
    else
      redirect_to receipt_path(@receipt), alert: result.failure.error, status: :see_other
    end
  end

  private

    def set_tenancy
      if params[:tenancy_id]
        @tenancy = authenticated_user.tenancies
                                    .includes({ tenancy_parties: :party }, { rentable_unit: :property })
                                    .find(params[:tenancy_id])
      end
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
      @parties = authenticated_user.parties.order(:display_name)
      if (t = @tenancy)
        @balance_cents = Accounting::TenancyBalanceQuery.balance_cents_as_of(tenancy: t, as_of: Date.current)
      else
        @tenancies = authenticated_user.tenancies.includes({ tenancy_parties: :party }, :property, :rentable_unit).order(:id)
      end
    end

    # Validation failures render the same form the request came from: the
    # dialog re-renders inside the modal frame with a 422; standalone pages
    # (which submit to an explicit .html action URL) re-render the full page.
    def render_receipt_failure
      load_form_collections
      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.turbo_stream do
          if (t = @tenancy)
            render turbo_stream: turbo_stream.update("modal-frame",
                     partial: "receipts/form",
                     locals: { receipt: @receipt, fixed_tenancy: t, form_context: :dialog, parties: @parties, balance_cents: @balance_cents }),
                   status: :unprocessable_content
          else
            render :new, formats: [ :html ], content_type: "text/html", status: :unprocessable_content
          end
        end
      end
    end
end
