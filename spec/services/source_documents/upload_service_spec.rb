require "rails_helper"

RSpec.describe SourceDocuments::UploadService do
  let(:user) { create(:user) }

  describe "#call" do
    it "uploads a valid PDF and queues an IngestSourceDocumentJob" do
      pdf_file = fixture_file_upload(
        "receipts/202604 Zelle.pdf",
        "application/pdf"
      )

      expect {
        result = described_class.call(user: user, pdf_param: pdf_file)
        expect(result).to be_success
        doc = result.value!.data[:source_document]
        expect(result.value!.data[:upload_status]).to eq(:queued)
        expect(doc.user).to eq(user)
        expect(doc.status).to eq("processing")
        expect(doc.document_type).to eq("unknown")
      }.to have_enqueued_job(IngestSourceDocumentJob)
       .and change(SourceDocument, :count).by(1)
    end

    it "rejects missing file" do
      result = described_class.call(user: user, pdf_param: nil)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:missing_file)
    end

    it "rejects non-PDF file header" do
      file = StringIO.new("not a real pdf header")
      def file.original_filename; "test.txt"; end
      def file.content_type; "text/plain"; end
      def file.size; 20; end

      result = described_class.call(user: user, pdf_param: file)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_file_type)
    end

    it "rejects file exceeding 10MB limit" do
      file = StringIO.new("%PDF-1.4")
      def file.original_filename; "large.pdf"; end
      def file.content_type; "application/pdf"; end
      def file.size; 11.megabytes; end

      result = described_class.call(user: user, pdf_param: file)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:file_too_large)
    end

    it "handles ActiveRecord::RecordInvalid" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      allow(user.source_documents).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(SourceDocument.new))

      result = described_class.call(user: user, pdf_param: pdf_file)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:validation_error)
    end

    it "handles unexpected exceptions" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      allow(user.source_documents).to receive(:find_by).and_return(nil)
      allow(user.source_documents).to receive(:create!).and_raise(StandardError, "Unexpected disk failure")

      result = described_class.call(user: user, pdf_param: pdf_file)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:unexpected_error)
    end

    it "returns existing SourceDocument without enqueuing a duplicate job when identical file is uploaded twice sequentially" do
      pdf_file1 = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      pdf_file2 = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")

      res1 = described_class.call(user: user, pdf_param: pdf_file1)
      expect(res1).to be_success
      doc1 = res1.value!.data[:source_document]
      expect(res1.value!.data[:upload_status]).to eq(:queued)

      expect {
        res2 = described_class.call(user: user, pdf_param: pdf_file2)
        expect(res2).to be_success
        doc2 = res2.value!.data[:source_document]
        expect(res2.value!.data[:upload_status]).to eq(:already_processing)
        expect(doc2.id).to eq(doc1.id)
      }.not_to have_enqueued_job(IngestSourceDocumentJob)

      expect(user.source_documents.count).to eq(1)
    end

    it "distinguishes status for existing processed vs failed vs processing documents" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      res1 = described_class.call(user: user, pdf_param: pdf_file)
      doc = res1.value!.data[:source_document]

      # When existing document is success
      doc.update_columns(status: "success")
      pdf_file2 = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      res2 = described_class.call(user: user, pdf_param: pdf_file2)
      expect(res2).to be_success
      expect(res2.value!.data[:upload_status]).to eq(:already_processed)

      # When existing document is failed
      doc.update_columns(status: "failed", error_message: "Parse error")
      pdf_file3 = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      res3 = described_class.call(user: user, pdf_param: pdf_file3)
      expect(res3).to be_success
      expect(res3.value!.data[:upload_status]).to eq(:retry_required)
    end

    it "safely handles concurrent duplicate uploads returning the same SourceDocument" do
      res1 = nil
      res2 = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
          res1 = described_class.call(user: user, pdf_param: pdf_file)
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
          res2 = described_class.call(user: user, pdf_param: pdf_file)
        end
      end

      [ t1, t2 ].each(&:join)

      expect(res1).to be_success
      expect(res2).to be_success
      expect(res1.value!.data[:source_document].id).to eq(res2.value!.data[:source_document].id)
      expect(user.source_documents.count).to eq(1)
    end

    it "does not queue a new background job when an existing failed document is re-uploaded" do
      pdf_file1 = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      res1 = described_class.call(user: user, pdf_param: pdf_file1)
      expect(res1).to be_success
      doc = res1.value!.data[:source_document]
      doc.update_columns(status: "failed", error_message: "Simulated parse failure")

      pdf_file2 = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      expect {
        res2 = described_class.call(user: user, pdf_param: pdf_file2)
        expect(res2).to be_success
        expect(res2.value!.data[:source_document].id).to eq(doc.id)
        expect(res2.value!.data[:upload_status]).to eq(:retry_required)
      }.not_to have_enqueued_job(IngestSourceDocumentJob)

      expect(doc.reload.status).to eq("failed")
    end

    it "transitions SourceDocument to failed on enqueue error, ensuring concurrent duplicate upload sees a durable recoverable document" do
      pdf_file1 = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      pdf_file2 = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")

      allow(IngestSourceDocumentJob).to receive(:perform_later).and_raise(StandardError, "Queue connection error")

      expect {
        result = described_class.call(user: user, pdf_param: pdf_file1)
        expect(result).to be_failure
        expect(result.failure.code).to eq(:unexpected_error)
      }.to change(SourceDocument, :count).by(1)

      doc = user.source_documents.first
      expect(doc.status).to eq("failed")
      expect(doc.error_message).to include("Queue connection error")

      # Concurrent or subsequent upload observes the durable document without disappearing
      allow(IngestSourceDocumentJob).to receive(:perform_later).and_call_original
      res2 = described_class.call(user: user, pdf_param: pdf_file2)
      expect(res2).to be_success
      expect(res2.value!.data[:source_document].id).to eq(doc.id)
      expect(res2.value!.data[:upload_status]).to eq(:retry_required)
      expect(SourceDocument.exists?(res2.value!.data[:source_document].id)).to be(true)

      # User can retry the durable failed document
      retry_res = SourceDocuments::RetryService.call(user: user, document: doc)
      expect(retry_res).to be_success
      expect(doc.reload.status).to eq("processing")
    end

    it "handles concurrent duplicate upload where initial upload encounters enqueue failure" do
      res1 = nil
      res2 = nil
      q1 = Queue.new

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
          allow(IngestSourceDocumentJob).to receive(:perform_later) do
            q1.push(:created)
            raise StandardError, "Queue timeout"
          end
          res1 = described_class.call(user: user, pdf_param: pdf_file)
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          q1.pop
          pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
          res2 = described_class.call(user: user, pdf_param: pdf_file)
        end
      end

      [ t1, t2 ].each(&:join)

      expect(user.source_documents.count).to eq(1)
      doc = user.source_documents.first
      expect(doc.status).to eq("failed")

      expect(res1).to be_failure
      expect(res2).to be_success
      expect(res2.value!.data[:source_document].id).to eq(doc.id)
      expect(SourceDocument.exists?(res2.value!.data[:source_document].id)).to be(true)
    end

    it "returns validation error when document creation fails validation" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      allow(user.source_documents).to receive(:create!).and_raise(
        ActiveRecord::RecordInvalid.new(SourceDocument.new.tap { |d| d.errors.add(:base, "Invalid document structure") })
      )
      res = described_class.call(user: user, pdf_param: pdf_file)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:validation_error)
    end

    it "returns :already_processing for existing document with status 'processing' or other status" do
      pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      res1 = described_class.call(user: user, pdf_param: pdf_file)
      expect(res1).to be_success
      doc = res1.value!.data[:source_document]
      doc.update_columns(status: "custom_status")

      pdf_file2 = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
      res2 = described_class.call(user: user, pdf_param: pdf_file2)
      expect(res2).to be_success
      expect(res2.value!.data[:upload_status]).to eq(:already_processing)
    end
  end
end
