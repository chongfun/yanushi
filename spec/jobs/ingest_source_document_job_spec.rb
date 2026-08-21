require "rails_helper"

RSpec.describe IngestSourceDocumentJob, type: :job do
  let(:user) { create(:user) }
  let!(:party) { create(:party, user: user, display_name: "Jane Smith") }
  let!(:property) { create(:property, user: user) }
  let!(:unit) { create(:rentable_unit, property: property) }
  let!(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), termination_date: nil) }

  before do
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: Date.new(2023, 1, 1))
  end

  it "returns immediately if source document does not exist" do
    expect {
      described_class.perform_now(999_999)
    }.not_to raise_error
  end

  it "performs successfully for valid pdf" do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
    pdf_bytes = File.binread(pdf_path)

    doc = create(
      :source_document,
      user: user,
      attachment_file: pdf_bytes,
      attachment_filename: "202604 Zelle.pdf",
      attachment_content_type: "application/pdf",
      status: "processing"
    )

    expect {
      described_class.perform_now(doc.id)
    }.to change(ImportedTransaction, :count).by(1)

    doc.reload
    expect(doc.status).to eq("success")
    expect(doc.error_message).to be_nil

    txn = ImportedTransaction.last
    expect(txn.payment_method).to eq("zelle")
    expect(txn.matched_party).to eq(party)
    expect(txn.matched_tenancy).to eq(tenancy)
  end

  it "handles failure result from IngestionService" do
    doc = create(
      :source_document,
      user: user,
      attachment_file: "not valid pdf content",
      attachment_filename: "invalid.pdf",
      attachment_content_type: "application/pdf",
      status: "processing"
    )

    described_class.perform_now(doc.id)

    doc.reload
    expect(doc.status).to eq("failed")
    expect(doc.error_message).to be_present
  end

  it "rescues unexpected exceptions" do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
    pdf_bytes = File.binread(pdf_path)

    doc = create(
      :source_document,
      user: user,
      attachment_file: pdf_bytes,
      attachment_filename: "202604 Zelle.pdf",
      attachment_content_type: "application/pdf",
      status: "processing"
    )

    allow(ImportedTransactions::IngestionService).to receive(:call).and_raise(StandardError, "Unexpected worker error")

    described_class.perform_now(doc.id)

    doc.reload
    expect(doc.status).to eq("failed")
    expect(doc.error_message).to eq("Unexpected worker error")
  end

  it "preserves success status when a failing job races with a concurrently successful job" do
    pdf_text = <<~TEXT
      CHASE TOTAL CHECKING
      July 01, 2026 through July 31, 2026
      TRANSACTION DETAIL
      DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
      07/02     Oak Vly Com Bnk  P2P        Jane Smith   Web ID: 9000000021                     300.00        1,300.00
      07/15     Oak Vly Com Bnk  P2P        Jane Smith   Web ID: 9000000021                     200.00        1,500.00
    TEXT

    doc = HexaPDF::Document.new
    page = doc.pages.add
    canvas = page.canvas
    canvas.font("Helvetica", size: 10)
    y = 700
    pdf_text.split("\n").each do |line|
      canvas.text(line, at: [ 50, y ])
      y -= 15
    end
    io = StringIO.new
    doc.write(io)
    pdf_bytes = io.string

    source_doc = create(
      :source_document,
      user: user,
      attachment_file: pdf_bytes,
      attachment_filename: "chase.pdf",
      attachment_content_type: "application/pdf",
      status: "processing"
    )

    call_count = Concurrent::AtomicFixnum.new(0)

    allow_any_instance_of(ImportedTransaction).to receive(:save!).and_wrap_original do |m, *args|
      cnt = call_count.increment
      if cnt == 2
        raise StandardError, "Simulated worker crash during candidate save"
      end
      m.call(*args)
    end

    t1 = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.perform_now(source_doc.id)
      end
    end

    t2 = Thread.new do
      sleep 0.05
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.perform_now(source_doc.id)
      end
    end

    [ t1, t2 ].each(&:join)

    source_doc.reload
    expect(source_doc.status).to eq("success")
    expect(source_doc.imported_transactions.count).to eq(2)
  end
end
