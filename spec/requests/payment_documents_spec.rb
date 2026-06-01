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
  end
end
