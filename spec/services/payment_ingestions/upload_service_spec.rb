require "rails_helper"

RSpec.describe PaymentIngestions::UploadService do
  UploadedFile = Struct.new(:content, :original_filename, :content_type, :reported_size) do
    def read(length = nil)
      io.read(length)
    end

    def rewind
      io.rewind
    end

    def size
      reported_size || content.bytesize
    end

    private

    def io
      @io ||= StringIO.new(content)
    end
  end

  let(:user) { create(:user) }

  it "rejects a missing file" do
    result = described_class.call(user: user, pdf_param: nil)

    expect(result).to be_failure
    expect(result.error).to eq("Please select a PDF file to upload.")
  end

  it "rejects non-PDF content" do
    result = described_class.call(user: user, pdf_param: UploadedFile.new("plain text", "receipt.pdf", "application/pdf"))

    expect(result).to be_failure
    expect(result.error).to eq("Only PDF files are supported.")
  end

  it "rejects files over 10MB" do
    result = described_class.call(user: user, pdf_param: UploadedFile.new("%PDF-1.4", "receipt.pdf", "application/pdf", 11.megabytes))

    expect(result).to be_failure
    expect(result.error).to eq("File size exceeds the 10MB limit.")
  end

  it "creates a payment document and enqueues ingestion" do
    allow(IngestPaymentDocumentJob).to receive(:perform_later)

    expect {
      result = described_class.call(user: user, pdf_param: UploadedFile.new("%PDF-1.4 body", "receipt.pdf", "application/pdf"))
      expect(result).to be_success
      expect(result.data).to be_a(PaymentDocument)
    }.to change(PaymentDocument, :count).by(1)

    document = PaymentDocument.last
    expect(document.attachment_filename).to eq("receipt.pdf")
    expect(document.status).to eq("processing")
    expect(IngestPaymentDocumentJob).to have_received(:perform_later).with(document.id)
  end
end
