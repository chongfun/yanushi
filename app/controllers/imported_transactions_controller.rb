class ImportedTransactionsController < ApplicationController
  before_action :set_transaction, only: %i[show update destroy confirm]

  def index
    user = authenticated_user
    result = ImportedTransactions::IndexQuery.new(user: user).call(page: params[:page])

    @reviewable_transactions = result.reviewable_transactions
    @per_page = result.per_page
    @page = result.page
    @total_confirmed_count = result.total_confirmed_count
    @total_pages = result.total_pages
    @confirmed_transactions = result.confirmed_transactions
    @processing_documents = result.processing_documents
    @failed_documents = result.failed_documents
  end

  def show
    set_form_data
  end

  def update
    result = ImportedTransactions::UpdateService.call(
      user: authenticated_user,
      transaction: @transaction,
      params: imported_transaction_params
    )
    if result.success?
      redirect_to imported_transaction_path(@transaction), notice: "Transaction record updated successfully."
    else
      flash.now[:alert] = result.failure.error
      set_form_data
      render :show, status: :unprocessable_content
    end
  end

  def confirm
    create_alias = params[:create_alias] == "1"

    result = ImportedTransactions::ConfirmService.call(
      user: authenticated_user,
      transaction: @transaction,
      create_alias: create_alias
    )

    if result.success?
      redirect_to imported_transactions_path, notice: "Transaction confirmed and recorded successfully."
    else
      redirect_to imported_transaction_path(@transaction), alert: result.failure.error
    end
  rescue StandardError => e
    Rails.logger.error("Confirm transaction failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    redirect_to imported_transaction_path(@transaction), alert: "Failed to confirm transaction: An unexpected error occurred."
  end

  def destroy
    result = ImportedTransactions::DestroyService.call(user: authenticated_user, transaction: @transaction)
    if result.success?
      redirect_to imported_transactions_path, notice: "Imported transaction was deleted.", status: :see_other
    else
      redirect_to imported_transaction_path(@transaction), alert: result.failure.error
    end
  end

  private

    def set_transaction
      @transaction = authenticated_user.imported_transactions.find(params[:id])
    end

    def imported_transaction_params
      permitted_params = params.require(:imported_transaction).permit(
        :matched_party_id, :matched_tenancy_id, :transaction_kind, :amount, :occurred_on, :payment_method, :external_reference
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

    def set_form_data
      result = ImportedTransactions::FormDataQuery.new(user: authenticated_user).call
      @parties = result.parties
      @tenancies = result.tenancies
      @party_tenancies_map = result.party_tenancies_map
      @tenancy_parties_map = result.tenancy_parties_map
    end
end
