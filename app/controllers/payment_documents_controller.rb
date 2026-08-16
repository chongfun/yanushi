class PaymentDocumentsController < ApplicationController
  def destroy
    document = authenticated_user.payment_documents.find(params[:id])
    result = PaymentDocuments::DestroyService.call(user: authenticated_user, document: document)
    if result.success?
      redirect_to payment_ingestions_path, notice: "Upload record was removed.", status: :see_other
    else
      redirect_to payment_ingestions_path, alert: result.failure.error, status: :see_other
    end
  end
end
