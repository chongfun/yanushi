class PaymentDocumentsController < ApplicationController
  def destroy
    document = authenticated_user.payment_documents.find(params[:id])
    document.destroy!
    redirect_to payment_ingestions_path, notice: "Upload record was removed.", status: :see_other
  end
end
