require 'rails_helper'

RSpec.describe IngestPaymentDocumentJob, type: :job do
  let(:user) { create(:user) }
  let!(:tenant) { create(:tenant, user: user, name: "Jane Smith") }
  let!(:lease) { create(:lease, rental_property: create(:rental_property, user: user), lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0) }

  before do
    create(:lease_tenant, lease: lease, tenant: tenant)
  end

  it 'performs successfully for valid pdf' do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
    pdf_bytes = File.binread(pdf_path)

    doc = create(:payment_document,
      user: user,
      attachment_file: pdf_bytes,
      attachment_filename: "202604 Zelle.pdf",
      attachment_content_type: "application/pdf",
      status: :processing
    )

    expect {
      IngestPaymentDocumentJob.perform_now(doc.id)
    }.to change(PaymentIngestion, :count).by(1)

    doc.reload
    expect(doc.status).to eq("success")
    expect(doc.error_message).to be_nil

    ingestion = PaymentIngestion.last
    expect(ingestion.receipt_type).to eq("zelle")
    expect(ingestion.tenant).to eq(tenant)
    expect(ingestion.lease).to eq(lease)
  end

  it 'fails and updates document on invalid document structure' do
    doc = create(:payment_document,
      user: user,
      attachment_file: "invalid pdf data",
      attachment_filename: "invalid.pdf",
      attachment_content_type: "application/pdf",
      status: :processing
    )

    expect {
      IngestPaymentDocumentJob.perform_now(doc.id)
    }.not_to change(PaymentIngestion, :count)

    doc.reload
    expect(doc.status).to eq("failed")
    expect(doc.error_message).not_to be_nil
  end

  it 'transaction rolls back all ingestion creation on parsing failure' do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
    pdf_bytes = File.binread(pdf_path)

    doc = create(:payment_document,
      user: user,
      attachment_file: pdf_bytes,
      attachment_filename: "202604 Zelle.pdf",
      attachment_content_type: "application/pdf",
      status: :processing
    )

    # Mock TenantResolver.resolve to raise an error
    allow_any_instance_of(PaymentIngestions::TenantResolver).to receive(:resolve).and_raise("Forced resolve error")

    expect {
      IngestPaymentDocumentJob.perform_now(doc.id)
    }.not_to change(PaymentIngestion, :count)

    doc.reload
    expect(doc.status).to eq("failed")
    expect(doc.error_message).to eq("Forced resolve error")
  end
end
