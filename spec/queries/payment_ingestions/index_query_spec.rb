require "rails_helper"

RSpec.describe PaymentIngestions::IndexQuery do
  let(:user) { create(:user) }

  it "returns review queues, document queues, and paginated history for a user" do
    create(:payment_ingestion, user: user, status: :matched)
    create(:payment_ingestion, user: user, status: :unmatched)
    22.times do |index|
      create(:payment_ingestion,
        user: user,
        status: :confirmed,
        source: "pdf_upload",
        payment_method: "zelle",
        transaction_number: "HIST#{index}"
      )
    end
    processing_document = create(:payment_document, user: user, status: :processing)
    failed_document = create(:payment_document, user: user, status: :failed)
    other_user = create(:user)
    create(:payment_ingestion, user: other_user, status: :matched)
    create(:payment_document, user: other_user, status: :failed)

    result = described_class.new(user: user).call(page: 2)

    expect(result.reviewable_ingestions.count).to eq(2)
    expect(result.total_confirmed_count).to eq(22)
    expect(result.confirmed_ingestions.count).to eq(2)
    expect(result.page).to eq(2)
    expect(result.processing_documents).to contain_exactly(processing_document)
    expect(result.failed_documents).to contain_exactly(failed_document)
  end
end
