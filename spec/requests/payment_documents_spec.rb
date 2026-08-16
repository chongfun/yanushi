require 'rails_helper'

RSpec.describe "PaymentDocuments", type: :request do
  let(:user) { create(:user) }

  before { sign_in_as(user) }

  describe "DELETE /destroy" do
    it "destroys the upload record and redirects" do
      document = create(:payment_document, user: user)

      expect {
        delete payment_document_url(document)
      }.to change(PaymentDocument, :count).by(-1)

      expect(response).to redirect_to(payment_ingestions_path)
    end

    it "refuses to destroy document with confirmed ingestions and sets alert" do
      document = create(:payment_document, user: user)
      create(:payment_ingestion, user: user, payment_document: document, status: :confirmed)

      expect {
        delete payment_document_url(document)
      }.not_to change(PaymentDocument, :count)

      expect(response).to redirect_to(payment_ingestions_path)
      expect(flash[:alert]).to include("Cannot delete document with confirmed payment ingestions")
    end
  end
end
