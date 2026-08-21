require "rails_helper"

RSpec.describe ImportedTransactions::IngestionService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party) { create(:party, user: user, display_name: "Jane Doe") }
  let!(:tenancy) do
    t = create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
    create(:tenancy_party, tenancy: t, party: party, role: "tenant")
    t
  end

  def create_pdf_io(text, pages: 1)
    doc = HexaPDF::Document.new
    pages.times do
      page = doc.pages.add
      canvas = page.canvas
      canvas.font("Helvetica", size: 10)
      y = 700
      text.split("\n").each do |line|
        canvas.text(line, at: [ 50, y ])
        y -= 15
      end
    end
    io = StringIO.new
    doc.write(io)
    io.rewind
    io
  end

  describe "#call" do
    it "ingests a single Zelle receipt with amount_cents and defaults kind to unknown without posting to ledger" do
      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number 123456789
      TEXT

      io = create_pdf_io(pdf_text)

      expect {
        result = described_class.call(user: user, pdf_path_or_io: io)
        expect(result).to be_success
        txns = result.value!.data[:imported_transactions]
        expect(txns.size).to eq(1)

        txn = txns.first
        expect(txn.user).to eq(user)
        expect(txn.transaction_kind).to eq("unknown")
        expect(txn.status).to eq("matched")
        expect(txn.amount_cents).to eq(125_000)
        expect(txn.occurred_on).to eq(Date.new(2026, 3, 24))
        expect(txn.payment_method).to eq("zelle")
        expect(txn.external_reference).to eq("123456789")
        expect(txn.matched_party).to eq(party)
        expect(txn.matched_tenancy).to eq(tenancy)
      }.to change(SourceDocument, :count).by(1)
       .and change(ImportedTransaction, :count).by(1)
       .and change(JournalEntry, :count).by(0)
       .and change(Posting, :count).by(0)
    end

    it "ingests from an existing persisted SourceDocument record" do
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

      result = described_class.call(user: user, pdf_path_or_io: doc)
      expect(result).to be_success
      doc.reload
      expect(doc.status).to eq("success")
    end

    it "rejects ingesting a SourceDocument that belongs to another user" do
      other_user = create(:user)
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      pdf_bytes = File.binread(pdf_path)

      other_doc = create(
        :source_document,
        user: other_user,
        attachment_file: pdf_bytes,
        attachment_filename: "202604 Zelle.pdf",
        attachment_content_type: "application/pdf",
        status: "processing"
      )

      result = described_class.call(user: user, pdf_path_or_io: other_doc)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
      expect(other_doc.reload.status).to eq("processing")
      expect(ImportedTransaction.count).to eq(0)
    end

    it "ingests from a file path string" do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf").to_s
      result = described_class.call(user: user, pdf_path_or_io: pdf_path)
      expect(result).to be_success
    end

    it "ingests a Venmo receipt" do
      pdf_text = <<~TEXT
        Transaction details
        Jane Doe
        Received from @janedoe-123
        Amount: $1,400.00
        Date: Mar 1, 2026, 6:41 PM
        Transaction ID 987654321
      TEXT

      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_success
      txns = result.value!.data[:imported_transactions]
      expect(txns.first.payment_method).to eq("venmo")
      expect(txns.first.matched_party).to eq(party)
      expect(txns.first.external_reference).to eq("987654321")
    end

    it "marks status as ambiguous when multiple active tenancies match the party on occurred_on" do
      unit2 = create(:rentable_unit, property: property)
      t2 = create(:tenancy, rentable_unit: unit2, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
      create(:tenancy_party, tenancy: t2, party: party, role: "tenant")

      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number 123456789
      TEXT

      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_success
      txn = result.value!.data[:imported_transactions].first
      expect(txn.status).to eq("ambiguous")
      expect(txn.matched_tenancy).to be_nil
    end

    it "skips duplicate candidate creation if external identity already exists" do
      create(
        :imported_transaction,
        user: user,
        source: "pdf_upload",
        payment_method: "zelle",
        external_reference: "123456789",
        status: "pending"
      )

      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number 123456789
      TEXT

      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_success
      expect(result.value!.data[:imported_transactions]).to be_empty
    end

    it "retains unmatched Chase statement transactions as reviewable unmatched candidates rather than dropping them" do
      pdf_text = <<~TEXT
        CHASE TOTAL CHECKING
        March 18, 2026 through April 16, 2026
        TRANSACTION DETAIL
        03/24     Zelle Payment From Jane Doe Pncaa0Yqh12Q                            1,250.00        2,850.00
        04/01     Oak Vly Com Bnk  P2P        Unregistered Person Web ID: 9988776655   1,000.00        3,850.00
      TEXT

      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_success
      txns = result.value!.data[:imported_transactions]
      expect(txns.size).to eq(2)

      matched_txn = txns.find { |t| t.payer_name == "Jane Doe" }
      expect(matched_txn.status).to eq("matched")
      expect(matched_txn.matched_party).to eq(party)
      expect(matched_txn.transaction_kind).to eq("unknown")

      unmatched_txn = txns.find { |t| t.payer_name == "Unregistered Person" }
      expect(unmatched_txn.status).to eq("unmatched")
      expect(unmatched_txn.matched_party).to be_nil
      expect(unmatched_txn.transaction_kind).to eq("unknown")
      expect(unmatched_txn.amount_cents).to eq(100_000)
    end

    it "fails when Chase statement contains no transaction lines" do
      pdf_text = <<~TEXT
        CHASE TOTAL CHECKING
        March 18, 2026 through April 16, 2026
        TRANSACTION DETAIL
      TEXT

      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:no_transactions_found)
    end

    it "creates a failed imported transaction when parser returns failure on a single receipt" do
      allow_any_instance_of(ImportedTransactions::Parsers::Zelle).to receive(:parse).and_return(
        ImportedTransactions::IngestionResult.failure(error_message: "Corrupted PDF segment")
      )

      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number 123456789
      TEXT

      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_success
      txn = result.value!.data[:imported_transactions].first
      expect(txn.status).to eq("failed")
      expect(txn.error_message).to eq("Corrupted PDF segment")
    end

    it "rejects unrecognized document formats" do
      pdf_text = "Random invoice without recognizable layout"
      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:unrecognized_format)
    end

    it "rejects multi-page non-statement receipts" do
      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number 123456789
      TEXT
      io = create_pdf_io(pdf_text, pages: 2)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:unsupported_pages)
    end

    it "ingests all 3 distinct Chase P2P credits sharing the same Web ID" do
      pdf_text = <<~TEXT
        CHASE TOTAL CHECKING
        July 01, 2026 through July 31, 2026
        TRANSACTION DETAIL
        DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
        07/02     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     300.00        1,300.00
        07/15     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     200.00        1,500.00
        07/18     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                   1,100.00        2,600.00
      TEXT
      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_success
      txns = result.value!.data[:imported_transactions]
      expect(txns.size).to eq(3)

      expect(txns[0].amount_cents).to eq(30_000)
      expect(txns[0].occurred_on).to eq(Date.new(2026, 7, 2))
      expect(txns[0].external_reference).to be_nil
      expect(txns[0].status).to eq("matched")

      expect(txns[1].amount_cents).to eq(20_000)
      expect(txns[1].occurred_on).to eq(Date.new(2026, 7, 15))
      expect(txns[1].external_reference).to be_nil
      expect(txns[1].status).to eq("matched")

      expect(txns[2].amount_cents).to eq(110_000)
      expect(txns[2].occurred_on).to eq(Date.new(2026, 7, 18))
      expect(txns[2].external_reference).to be_nil
      expect(txns[2].status).to eq("matched")
    end

    it "safely handles concurrent duplicate upload without failing the document" do
      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number RACE123456
      TEXT

      pdf_bytes1 = create_pdf_io("#{pdf_text}\nDoc 1").read
      pdf_bytes2 = create_pdf_io("#{pdf_text}\nDoc 2").read

      doc1 = create(:source_document, user: user, attachment_file: pdf_bytes1, attachment_filename: "r1.pdf", status: "processing")
      doc2 = create(:source_document, user: user, attachment_file: pdf_bytes2, attachment_filename: "r2.pdf", status: "processing")

      res1 = nil
      res2 = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res1 = described_class.call(user: user, pdf_path_or_io: doc1)
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res2 = described_class.call(user: user, pdf_path_or_io: doc2)
        end
      end

      [ t1, t2 ].each(&:join)

      expect(res1).to be_success
      expect(res2).to be_success

      expect(doc1.reload.status).to eq("success")
      expect(doc2.reload.status).to eq("success")

      expect(ImportedTransaction.where(user: user, external_reference: "RACE123456").count).to eq(1)
    end

    it "re-raises unexpected validation errors during candidate save" do
      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number ERR123456
      TEXT
      io = create_pdf_io(pdf_text)

      allow_any_instance_of(ImportedTransaction).to receive(:save!).and_wrap_original do |m, *args|
        txn = m.receiver
        txn.errors.add(:base, "Database corrupted")
        raise ActiveRecord::RecordInvalid.new(txn)
      end

      expect {
        described_class.call(user: user, pdf_path_or_io: io)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "ignores failed line parse results in Chase statement without creating failed transaction candidate" do
      allow_any_instance_of(ImportedTransactions::Parsers::ChaseStatement).to receive(:parse).and_return([
        ImportedTransactions::IngestionResult.failure(error_message: "Corrupted line")
      ])

      pdf_text = <<~TEXT
        CHASE TOTAL CHECKING
        March 18, 2026 through April 16, 2026
        TRANSACTION DETAIL
      TEXT
      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:no_transactions_found)
      expect(ImportedTransaction.count).to eq(0)
    end

    it "keeps ambiguous party match status when multiple active tenancies exist" do
      create(:party, user: user, display_name: "Jane Doe") # creates ambiguous party resolution
      unit2 = create(:rentable_unit, property: property)
      tenancy2 = create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2025, 1, 1))
      create(:tenancy_party, tenancy: tenancy2, party: party, role: "tenant")

      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number AMB123
      TEXT
      io = create_pdf_io(pdf_text)

      result = described_class.call(user: user, pdf_path_or_io: io)
      expect(result).to be_success
      txn = result.value!.data[:imported_transactions].first
      expect(txn.status).to eq("ambiguous")
    end

    it "returns existing candidates when same SourceDocument is processed twice sequentially" do
      pdf_text = <<~TEXT
        CHASE TOTAL CHECKING
        July 01, 2026 through July 31, 2026
        TRANSACTION DETAIL
        DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
        07/02     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     300.00        1,300.00
        07/15     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     200.00        1,500.00
      TEXT

      pdf_bytes = create_pdf_io(pdf_text).read

      doc = create(:source_document, user: user, attachment_file: pdf_bytes, attachment_filename: "chase.pdf", status: "processing")

      res1 = described_class.call(user: user, pdf_path_or_io: doc)
      expect(res1).to be_success
      expect(res1.value!.data[:imported_transactions].size).to eq(2)
      expect(doc.reload.status).to eq("success")

      # Second processing of the same document returns existing candidates
      res2 = described_class.call(user: user, pdf_path_or_io: doc)
      expect(res2).to be_success
      expect(res2.value!.data[:imported_transactions].size).to eq(2)

      # No duplicate candidates created
      expect(doc.imported_transactions.count).to eq(2)
    end

    it "creates only one candidate set when same SourceDocument is processed concurrently" do
      pdf_text = <<~TEXT
        CHASE TOTAL CHECKING
        July 01, 2026 through July 31, 2026
        TRANSACTION DETAIL
        DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
        07/02     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     300.00        1,300.00
        07/15     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     200.00        1,500.00
      TEXT

      pdf_bytes = create_pdf_io(pdf_text).read

      doc = create(:source_document, user: user, attachment_file: pdf_bytes, attachment_filename: "chase.pdf", status: "processing")

      res1 = nil
      res2 = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res1 = described_class.call(user: user, pdf_path_or_io: doc)
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res2 = described_class.call(user: user, pdf_path_or_io: doc)
        end
      end

      [ t1, t2 ].each(&:join)

      expect(res1).to be_success
      expect(res2).to be_success

      # Exactly 2 candidates total, not 4
      expect(doc.reload.imported_transactions.count).to eq(2)
      expect(doc.status).to eq("success")
    end

    it "rolls back partial candidates when an unexpected error occurs during persistence" do
      pdf_text = <<~TEXT
        CHASE TOTAL CHECKING
        July 01, 2026 through July 31, 2026
        TRANSACTION DETAIL
        DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
        07/02     Zelle Payment From Jane Doe Pncaa0Yqh12Q                            1,250.00        2,850.00
        07/15     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     200.00        1,500.00
      TEXT

      pdf_bytes = create_pdf_io(pdf_text).read

      doc = create(:source_document, user: user, attachment_file: pdf_bytes, attachment_filename: "chase.pdf", status: "processing")

      call_count = 0
      allow_any_instance_of(ImportedTransaction).to receive(:save!).and_wrap_original do |m, *args|
        call_count += 1
        if call_count == 2
          raise StandardError, "Simulated crash after first candidate"
        end
        m.call(*args)
      end

      expect {
        described_class.call(user: user, pdf_path_or_io: doc)
      }.to raise_error(StandardError, "Simulated crash after first candidate")

      # No partial candidates survive
      expect(doc.reload.imported_transactions.count).to eq(0)
      expect(doc.status).to eq("processing")
    end

    it "raises ActiveRecord::RecordInvalid and does not silently skip when external_reference is overlong (> 255 chars)" do
      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number 123456789
      TEXT

      io = create_pdf_io(pdf_text)

      allow_any_instance_of(ImportedTransactions::Parsers::Zelle).to receive(:parse).and_return(
        ImportedTransactions::IngestionResult.success(
          payer_name: "Jane Doe",
          payer_username: nil,
          amount_cents: 125_000,
          occurred_on: Date.new(2026, 3, 24),
          payment_method: "zelle",
          external_reference: "A" * 256,
          raw_text: pdf_text
        )
      )

      expect {
        described_class.call(user: user, pdf_path_or_io: io)
      }.to raise_error(ActiveRecord::RecordInvalid) do |e|
        expect(e.record.errors[:external_reference]).to include("is too long (maximum is 255 characters)")
      end
    end

    it "creates only one SourceDocument and one candidate set when same Chase PDF is ingested twice sequentially" do
      pdf_text = <<~TEXT
        CHASE TOTAL CHECKING
        July 01, 2026 through July 31, 2026
        TRANSACTION DETAIL
        DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
        07/02     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     300.00        1,300.00
        07/15     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     200.00        1,500.00
      TEXT

      pdf_bytes = create_pdf_io(pdf_text).read

      io1 = StringIO.new(pdf_bytes)
      res1 = described_class.call(user: user, pdf_path_or_io: io1)
      expect(res1).to be_success
      expect(res1.value!.data[:imported_transactions].size).to eq(2)
      doc1 = res1.value!.data[:source_document]

      io2 = StringIO.new(pdf_bytes)
      res2 = described_class.call(user: user, pdf_path_or_io: io2)
      expect(res2).to be_success
      expect(res2.value!.data[:imported_transactions].size).to eq(2)
      doc2 = res2.value!.data[:source_document]

      expect(doc2.id).to eq(doc1.id)
      expect(SourceDocument.where(user: user).count).to eq(1)
      expect(ImportedTransaction.where(user: user).count).to eq(2)
    end

    it "creates only one SourceDocument and one candidate set when same Chase PDF is ingested concurrently" do
      pdf_text = <<~TEXT
        CHASE TOTAL CHECKING
        July 01, 2026 through July 31, 2026
        TRANSACTION DETAIL
        DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
        07/02     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     300.00        1,300.00
        07/15     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     200.00        1,500.00
      TEXT

      pdf_bytes = create_pdf_io(pdf_text).read

      res1 = nil
      res2 = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res1 = described_class.call(user: user, pdf_path_or_io: StringIO.new(pdf_bytes))
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res2 = described_class.call(user: user, pdf_path_or_io: StringIO.new(pdf_bytes))
        end
      end

      [ t1, t2 ].each(&:join)

      expect(res1).to be_success
      expect(res2).to be_success
      expect(SourceDocument.where(user: user).count).to eq(1)
      expect(ImportedTransaction.where(user: user).count).to eq(2)
    end

    it "does not deduplicate transactions merely by amount/date/payer when PDF bytes are different" do
      pdf_text1 = <<~TEXT
        CHASE TOTAL CHECKING
        July 01, 2026 through July 31, 2026
        TRANSACTION DETAIL
        DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
        07/02     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     300.00        1,300.00
      TEXT

      pdf_text2 = <<~TEXT
        CHASE TOTAL CHECKING
        August 01, 2026 through August 31, 2026
        TRANSACTION DETAIL
        DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
        07/02     Oak Vly Com Bnk  P2P        Jane Doe     Web ID: 9000000021                     300.00        1,300.00
      TEXT

      io1 = create_pdf_io(pdf_text1)
      io2 = create_pdf_io(pdf_text2)

      res1 = described_class.call(user: user, pdf_path_or_io: io1)
      res2 = described_class.call(user: user, pdf_path_or_io: io2)

      expect(res1).to be_success
      expect(res2).to be_success

      # Two distinct documents and two distinct candidates
      expect(SourceDocument.where(user: user).count).to eq(2)
      expect(ImportedTransaction.where(user: user).count).to eq(2)
    end

    it "ingests a PDF from a Tempfile with path and original_filename" do
      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number 123456789
      TEXT

      pdf_io = create_pdf_io(pdf_text)
      tempfile = Tempfile.new([ "test_receipt", ".pdf" ])
      tempfile.binmode
      tempfile.write(pdf_io.read)
      tempfile.flush
      tempfile.rewind

      def tempfile.original_filename
        "custom_name.pdf"
      end

      res = described_class.call(user: user, pdf_path_or_io: tempfile)
      expect(res).to be_success
      expect(res.value!.data[:source_document].attachment_filename).to eq("custom_name.pdf")
      tempfile.close
      tempfile.unlink
    end

    it "ingests a PDF from a file path string" do
      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number 123456789
      TEXT

      pdf_io = create_pdf_io(pdf_text)
      tempfile = Tempfile.new([ "path_test", ".pdf" ])
      tempfile.binmode
      tempfile.write(pdf_io.read)
      tempfile.flush
      tempfile.close

      res = described_class.call(user: user, pdf_path_or_io: tempfile.path)
      expect(res).to be_success
      expect(res.value!.data[:imported_transactions].size).to eq(1)
      tempfile.unlink
    end

    it "skips intra-document duplicates if parser yields the same external reference twice" do
      pdf_text = <<~TEXT
        Completed                         Jane Doe
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number DUP123
      TEXT

      io = create_pdf_io(pdf_text)

      r1 = ImportedTransactions::IngestionResult.success(
        payer_name: "Jane Doe",
        payer_username: nil,
        amount_cents: 125_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle",
        external_reference: "DUP123",
        raw_text: pdf_text
      )
      r2 = ImportedTransactions::IngestionResult.success(
        payer_name: "Jane Doe",
        payer_username: nil,
        amount_cents: 125_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle",
        external_reference: "DUP123",
        raw_text: pdf_text
      )

      allow_any_instance_of(ImportedTransactions::Parsers::Zelle).to receive(:parse).and_return([ r1, r2 ])

      res = described_class.call(user: user, pdf_path_or_io: io)
      expect(res).to be_success
      expect(res.value!.data[:imported_transactions].size).to eq(1)
    end

    it "sets status to ambiguous when matched party belongs to multiple active tenancies" do
      prop1 = create(:property, user: user)
      unit1 = create(:rentable_unit, property: prop1)
      t1 = create(:tenancy, rentable_unit: unit1, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))

      prop2 = create(:property, user: user)
      unit2 = create(:rentable_unit, property: prop2)
      t2 = create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))

      payer = create(:party, user: user, display_name: "Multi Tenant")
      create(:tenancy_party, tenancy: t1, party: payer, effective_from: Date.new(2026, 1, 1), effective_until: Date.new(2026, 12, 31))
      create(:tenancy_party, tenancy: t2, party: payer, effective_from: Date.new(2026, 1, 1), effective_until: Date.new(2026, 12, 31))

      pdf_text = <<~TEXT
        Completed                         Multi Tenant
        In moments
        Amount: $1,250.00
        Date: Mar 24, 2026
        Transaction number MULTI999
      TEXT

      io = create_pdf_io(pdf_text)
      res = described_class.call(user: user, pdf_path_or_io: io)
      expect(res).to be_success
      txn = res.value!.data[:imported_transactions].first
      expect(txn.status).to eq("ambiguous")
      expect(txn.matched_party).to eq(payer)
      expect(txn.matched_tenancy).to be_nil
    end
  end
end
