class ImportedTransactionsController < ApplicationController
  before_action :set_transaction, only: %i[update destroy confirm]

  def index
    @view = params[:view].presence || "review"
    user = authenticated_user

    if @view == "history"
      @history_filters = history_filter_params
      history_result = ImportedTransactions::HistoryQuery.new(user: user).call(page: params[:page], filters: @history_filters)
      @confirmed_transactions = history_result.confirmed_transactions
      @page = history_result.page
      @per_page = history_result.per_page
      @total_pages = history_result.total_pages
      @total_confirmed_count = history_result.total_confirmed_count
      @review_count = history_result.review_count
      @processing_count = history_result.processing_count
      @failed_count = history_result.failed_count
      @history_count = history_result.history_count
      @inbox_revision = history_result.inbox_revision
      @reviewable_transactions = []
      @processing_documents = []
      @failed_documents = []
    elsif @view == "processing"
      @history_filters = {}
      proc_result = ImportedTransactions::ProcessingQuery.new(user: user).call
      @processing_documents = proc_result.processing_documents
      @failed_documents = proc_result.failed_documents
      @processing_count = proc_result.processing_count
      @failed_count = proc_result.failed_count
      @review_count = proc_result.review_count
      @history_count = proc_result.history_count
      @inbox_revision = proc_result.inbox_revision
      @reviewable_transactions = []
    else
      @history_filters = {}
      inbox_result = ImportedTransactions::InboxQuery.new(user: user).call
      @reviewable_transactions = inbox_result.reviewable_transactions
      @review_count = inbox_result.review_count
      @processing_count = inbox_result.processing_count
      @failed_count = inbox_result.failed_count
      @history_count = inbox_result.history_count
      @inbox_revision = inbox_result.inbox_revision
      @processing_documents = inbox_result.processing_documents
      @failed_documents = inbox_result.failed_documents

      if @reviewable_transactions.any?
        @selected_transaction = if params[:selected_id].present?
          @reviewable_transactions.find { |t| t.id == params[:selected_id].to_i } || @reviewable_transactions.first
        else
          @reviewable_transactions.first
        end
        set_form_data
      end
    end
  end

  def show
    set_form_data
    requested_id = params[:id].to_i
    inbox_result = ImportedTransactions::InboxQuery.new(
      user: authenticated_user,
      load_records: false,
      updated_transaction_id: requested_id
    ).call
    @processing_count = inbox_result.processing_count
    @failed_count = inbox_result.failed_count
    @inbox_revision = inbox_result.inbox_revision
    @review_count = inbox_result.review_count
    @next_transaction = inbox_result.next_transaction
    @transaction = inbox_result.updated_transaction

    if @transaction.nil?
      if turbo_frame_request? && turbo_frame_request_id == "inbox_review"
        render partial: "imported_transactions/review_detail",
               locals: {
                 transaction: @next_transaction,
                 review_context: :inbox,
                 parties: @parties,
                 tenancies: @tenancies,
                 party_tenancies_map: @party_tenancies_map,
                 tenancy_parties_map: @tenancy_parties_map,
                 processing_count: @processing_count,
                 failed_count: @failed_count,
                 review_count: @review_count,
                 inbox_revision: @inbox_revision,
                 stale_recovery: true,
                 focus_on_connect: true
               }
        return
      else
        if @next_transaction
          redirect_to imported_transaction_path(@next_transaction), status: :see_other
        else
          redirect_to inbox_path, status: :see_other
        end
        return
      end
    end

    if turbo_frame_request? && turbo_frame_request_id == "inbox_review"
      render partial: "imported_transactions/review_detail",
             locals: review_detail_locals(@transaction, focus_on_connect: true)
      return
    end

    @item_index = inbox_result.updated_transaction_position
    @reviewable_count = @review_count
  end

  def update
    txn = @transaction
    return unless txn

    @settled_transaction_id = txn.id

    result = ImportedTransactions::UpdateService.call(
      user: authenticated_user,
      transaction: txn,
      params: imported_transaction_params
    )
    set_counts_and_form_data(load_records: true, updated_transaction_id: txn.id)

    respond_to do |format|
      if result.success?
        format.html do
          if @transaction
            redirect_to imported_transaction_path(@transaction), notice: "Transaction record updated successfully.", status: :see_other
          elsif @next_transaction
            redirect_to imported_transaction_path(@next_transaction), notice: "Transaction record updated successfully.", status: :see_other
          else
            redirect_to inbox_path, notice: "Transaction record updated successfully.", status: :see_other
          end
        end
        format.turbo_stream { render :update }
      elsif result.failure.code == :gone
        @notice_message = "The transaction was deleted in another session."
        format.html do
          if @next_transaction
            redirect_to imported_transaction_path(@next_transaction), notice: @notice_message, status: :see_other
          else
            redirect_to inbox_path, notice: @notice_message, status: :see_other
          end
        end
        format.turbo_stream { render :update }
      else
        flash.now[:alert] = result.failure.error
        txn.assign_attributes(imported_transaction_params) if params[:imported_transaction].present?
        @transaction = txn
        format.html { render :show, status: :unprocessable_content }
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "inbox_review",
              partial: "imported_transactions/review_detail",
              locals: review_detail_locals(txn, focus_on_connect: true)
            ),
            turbo_stream.action("inbox_settle", "imported_transaction_#{txn.id}")
          ], status: :unprocessable_content
        end
      end
    end
  end

  def confirm
    txn = @transaction
    return unless txn

    @settled_transaction_id = txn.id

    create_alias = params[:create_alias] == "1"
    empty_params = {} # : Hash[Symbol, untyped]
    submitted_params = params[:imported_transaction].present? ? imported_transaction_params.to_h.symbolize_keys : empty_params

    result = ImportedTransactions::ConfirmService.call(
      user: authenticated_user,
      transaction: txn,
      params: submitted_params,
      create_alias: create_alias,
      requested_alias: params[:proposed_alias]
    )
    set_counts_and_form_data

    respond_to do |format|
      if result.success?
        format.html do
          if @next_transaction
            redirect_to imported_transaction_path(@next_transaction), notice: "Transaction confirmed and recorded successfully.", status: :see_other
          else
            redirect_to inbox_path, notice: "Transaction confirmed and recorded successfully.", status: :see_other
          end
        end
        format.turbo_stream { render :confirm }
      elsif result.failure.code == :gone
        @notice_message = "The transaction was deleted in another session."
        format.html do
          if @next_transaction
            redirect_to imported_transaction_path(@next_transaction), notice: @notice_message, status: :see_other
          else
            redirect_to inbox_path, notice: @notice_message, status: :see_other
          end
        end
        format.turbo_stream { render :confirm }
      else
        txn.assign_attributes(submitted_params) if submitted_params.present?
        @transaction = txn
        flash.now[:alert] = result.failure.error
        format.html { render :show, status: :unprocessable_content }
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "inbox_review",
              partial: "imported_transactions/review_detail",
              locals: review_detail_locals(txn, focus_on_connect: true)
            ),
            turbo_stream.action("inbox_settle", "imported_transaction_#{txn.id}")
          ], status: :unprocessable_content
        end
      end
    end
  end

  def destroy
    txn = @transaction
    return unless txn

    @settled_transaction_id = txn.id

    submitted_lock_version = params[:lock_version] || params.dig(:imported_transaction, :lock_version)
    result = ImportedTransactions::DestroyService.call(
      user: authenticated_user,
      transaction: txn,
      lock_version: submitted_lock_version
    )
    set_counts_and_form_data

    respond_to do |format|
      if result.success?
        format.html do
          if @next_transaction
            redirect_to imported_transaction_path(@next_transaction), notice: "Imported transaction was deleted.", status: :see_other
          else
            redirect_to inbox_path, notice: "Imported transaction was deleted.", status: :see_other
          end
        end
        format.turbo_stream { render :destroy }
      elsif result.failure.code == :gone
        @notice_message = "The transaction was deleted in another session."
        format.html do
          if @next_transaction
            redirect_to imported_transaction_path(@next_transaction), notice: @notice_message, status: :see_other
          else
            redirect_to inbox_path, notice: @notice_message, status: :see_other
          end
        end
        format.turbo_stream { render :destroy }
      else
        @transaction = txn
        flash.now[:alert] = result.failure.error
        format.html { render :show, status: :unprocessable_content }
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "inbox_review",
              partial: "imported_transactions/review_detail",
              locals: review_detail_locals(txn, focus_on_connect: true)
            ),
            turbo_stream.action("inbox_settle", "imported_transaction_#{txn.id}")
          ], status: :unprocessable_content
        end
      end
    end
  end

  private

    def review_detail_locals(txn, focus_on_connect: true)
      {
        transaction: txn,
        review_context: :inbox,
        parties: @parties,
        tenancies: @tenancies,
        party_tenancies_map: @party_tenancies_map,
        tenancy_parties_map: @tenancy_parties_map,
        processing_count: @processing_count,
        failed_count: @failed_count,
        review_count: @review_count,
        inbox_revision: @inbox_revision,
        focus_on_connect: focus_on_connect
      }
    end

    def set_transaction
      @transaction = authenticated_user.imported_transactions.find(params[:id])
    end

    def imported_transaction_params
      return {} unless params[:imported_transaction].present?

      permitted_params = params.require(:imported_transaction).permit(
        :matched_party_id, :matched_tenancy_id, :transaction_kind, :amount, :occurred_on, :payment_method, :external_reference, :lock_version
      )

      user = authenticated_user
      if permitted_params[:matched_party_id].present?
        raise ActiveRecord::RecordNotFound unless user.parties.where(id: permitted_params[:matched_party_id]).exists?
      end
      if permitted_params[:matched_tenancy_id].present?
        raise ActiveRecord::RecordNotFound unless user.tenancies.where(id: permitted_params[:matched_tenancy_id]).exists?
      end
      permitted_params
    end

    def history_filter_params
      params.permit(:search, :payment_method).to_h.symbolize_keys
    end

    def set_form_data
      result = ImportedTransactions::FormDataQuery.new(user: authenticated_user).call
      @parties = result.parties
      @tenancies = result.tenancies
      @party_tenancies_map = result.party_tenancies_map
      @tenancy_parties_map = result.tenancy_parties_map
    end

    def set_counts_and_form_data(load_records: true, updated_transaction_id: nil)
      user = authenticated_user
      inbox_result = ImportedTransactions::InboxQuery.new(
        user: user,
        load_records: load_records,
        updated_transaction_id: updated_transaction_id
      ).call
      @reviewable_transactions = inbox_result.reviewable_transactions
      @review_count = inbox_result.review_count
      @processing_count = inbox_result.processing_count
      @failed_count = inbox_result.failed_count
      @inbox_revision = inbox_result.inbox_revision
      @history_count = inbox_result.history_count
      @next_transaction = @reviewable_transactions.first
      if updated_transaction_id.present?
        @transaction = inbox_result.updated_transaction
      end
      set_form_data
    end
end
