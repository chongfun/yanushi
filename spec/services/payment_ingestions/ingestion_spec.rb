require "rails_helper"

RSpec.describe PaymentIngestions::Ingestion do
  let(:user) { create(:user, timezone: "Pacific Time (US & Canada)") }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:lease) do
    create(:tenancy,
      rentable_unit: unit,
      agreement_type: "fixed_term",
      commencement_date: Date.new(2023, 1, 1),
      termination_date: Date.new(2028, 12, 31),
      late_period_days: 5
    )
  end
  let!(:tenant) { create(:party, user: user, display_name: "Jane Smith") }

  before do
    create(:tenancy_party, tenancy: lease, party: tenant, role: "tenant", effective_from: Date.new(2023, 1, 1))
  end

  it "ingests Chase Zelle 202604 receipt PDF correctly" do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")

    expect {
      ingestion = described_class.new.call(
        user: user,
        pdf_path_or_io: pdf_path,
        source: "pdf_upload"
      )

      expect(ingestion.persisted?).to be_truthy
      expect(ingestion.receipt_type).to eq("zelle")
      expect(ingestion.status).to eq("matched")
      expect(ingestion.payer_name).to eq("JANE SMITH")
      expect(ingestion.payer_username).to be_nil
      expect(ingestion.amount).to eq(BigDecimal("1300.00"))
      expect(ingestion.payment_date).to eq(Date.new(2026, 3, 24))
      expect(ingestion.transaction_number).to eq("ZELNEW202604")
      expect(ingestion.party).to eq(tenant)
      expect(ingestion.tenancy).to eq(lease)
      expect(ingestion.attachment_attached?).to be_truthy
    }.to change(PaymentIngestion, :count).by(1)
  end

  it "ingests Chase Zelle 202312 receipt PDF correctly" do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202312 Security Deposit Zelle.pdf")

    expect {
      ingestion = described_class.new.call(
        user: user,
        pdf_path_or_io: pdf_path,
        source: "pdf_upload"
      )

      expect(ingestion.persisted?).to be_truthy
      expect(ingestion.receipt_type).to eq("zelle")
      expect(ingestion.status).to eq("matched")
      expect(ingestion.payer_name).to eq("JANE SMITH")
      expect(ingestion.payer_username).to be_nil
      expect(ingestion.amount).to eq(BigDecimal("1950.00"))
      expect(ingestion.payment_date).to eq(Date.new(2023, 12, 4))
      expect(ingestion.transaction_number).to eq("ZELNEW202312")
      expect(ingestion.party).to eq(tenant)
      expect(ingestion.tenancy).to eq(lease)
    }.to change(PaymentIngestion, :count).by(1)
  end

  it "ingests Venmo 202403 receipt PDF correctly" do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202403 Venmo.pdf")

    expect {
      ingestion = described_class.new.call(
        user: user,
        pdf_path_or_io: pdf_path,
        source: "pdf_upload"
      )

      expect(ingestion.persisted?).to be_truthy
      expect(ingestion.receipt_type).to eq("venmo")
      expect(ingestion.status).to eq("matched")
      expect(ingestion.payer_name).to eq("jane smith")
      expect(ingestion.payer_username).to eq("@janesmith")
      expect(ingestion.amount).to eq(BigDecimal("1000.00"))
      expect(ingestion.payment_date).to eq(Date.new(2024, 3, 1))
      expect(ingestion.transaction_number).to eq("9991209384910283")
      expect(ingestion.party).to eq(tenant)
      expect(ingestion.tenancy).to eq(lease)
    }.to change(PaymentIngestion, :count).by(1)
  end

  it "resolves tenant by alias when display name does not match" do
    tenant.update!(display_name: "Jane S. Smith")
    create(:party_alias, party: tenant, alias_name: "@janesmith")

    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202403 Venmo.pdf")

    ingestion = described_class.new.call(
      user: user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    expect(ingestion.status).to eq("matched")
    expect(ingestion.party).to eq(tenant)
  end

  it "resolves status to unmatched when no tenant matches" do
    tenant.update!(display_name: "Someone Else")
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")

    ingestion = described_class.new.call(
      user: user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    expect(ingestion.status).to eq("unmatched")
    expect(ingestion.party).to be_nil
  end

  it "resolves status to ambiguous when multiple tenants match display name or alias" do
    create(:party, user: user, display_name: "Jane Smith")
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")

    ingestion = described_class.new.call(
      user: user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    expect(ingestion.status).to eq("ambiguous")
    expect(ingestion.party).to be_nil
  end

  it "ingests multi-page bank statement and creates ingestion records for matched names" do
    lease.tenancy_parties.destroy_all
    tenant.destroy!

    alice = create(:party, user: user, display_name: "Alice Smith")
    charlie = create(:party, user: user, display_name: "Charlie Brown")
    bob = create(:party, user: user, display_name: "Bob Jones")

    u1 = create(:rentable_unit, property: property, name: "Unit 1")
    u2 = create(:rentable_unit, property: property, name: "Unit 2")
    u3 = create(:rentable_unit, property: property, name: "Unit 3")

    l1 = create(:tenancy, rentable_unit: u1, agreement_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), termination_date: nil)
    create(:tenancy_party, tenancy: l1, party: alice, role: "tenant", effective_from: Date.new(2023, 1, 1))

    l2 = create(:tenancy, rentable_unit: u2, agreement_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), termination_date: nil)
    create(:tenancy_party, tenancy: l2, party: charlie, role: "tenant", effective_from: Date.new(2023, 1, 1))

    l3 = create(:tenancy, rentable_unit: u3, agreement_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), termination_date: nil)
    create(:tenancy_party, tenancy: l3, party: bob, role: "tenant", effective_from: Date.new(2023, 1, 1))

    statement_path = Rails.root.join("spec/fixtures/files/statements/20260416-statements-1234-.pdf")

    expect {
      ingestions = described_class.new.call(
        user: user,
        pdf_path_or_io: statement_path,
        source: "pdf_upload"
      )

      expect(ingestions.size).to eq(3)

      ing_alice = ingestions.find { |i| i.payer_name == "Alice Smith" }
      expect(ing_alice).not_to be_nil
      expect(ing_alice.receipt_type).to eq("chase_statement")
      expect(ing_alice.status).to eq("matched")
      expect(ing_alice.amount).to eq(BigDecimal("1300.00"))
      expect(ing_alice.payment_date).to eq(Date.new(2026, 3, 24))
      expect(ing_alice.transaction_number).to eq("ZELNEW202604A")
      expect(ing_alice.party).to eq(alice)
      expect(ing_alice.tenancy).to eq(l1)

      doc = ing_alice.payment_document
      expect(doc).not_to be_nil
      expect(doc.attachment_filename).to eq("20260416-statements-1234-.pdf")
      expect(doc.attachment_content_type).to eq("application/pdf")
      expect(doc.payment_ingestions.count).to eq(3)
    }.to change(PaymentIngestion, :count).by(3)
  end

  describe "extract_pdf_data with PaymentDocument" do
    it "uses attachment_file directly when the attribute is loaded" do
      payment_doc = create(:payment_document, user: user, attachment_file: File.binread(Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")))
      ingestion_service = described_class.new
      expect(PaymentDocument).not_to receive(:where)
      ingestion_service.call(user: user, pdf_path_or_io: payment_doc)
    end

    it "queries the database for attachment_file when the attribute is not loaded" do
      payment_doc = create(:payment_document, user: user, attachment_file: File.binread(Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")))
      doc_without_blob = PaymentDocument.select(:id, :user_id, :attachment_filename, :attachment_content_type, :status).find(payment_doc.id)
      ingestion_service = described_class.new
      ingestion = ingestion_service.call(user: user, pdf_path_or_io: doc_without_blob)
      expect(ingestion.status).to eq("matched")
    end
  end

  describe "handles different io-like and file types" do
    it "handles IO-like object that responds to read and seek" do
      File.open(Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf"), "rb") do |file|
        ingestion = described_class.new.call(user: user, pdf_path_or_io: file)
        expect(ingestion.status).to eq("matched")
      end
    end

    it "handles string file paths" do
      pdf_path_str = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf").to_s
      ingestion = described_class.new.call(user: user, pdf_path_or_io: pdf_path_str)
      expect(ingestion.status).to eq("matched")
    end

    it "handles StringIO objects and triggers fallback filename" do
      pdf_data = File.binread(Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf"))
      io = StringIO.new(pdf_data)
      ingestion = described_class.new.call(user: user, pdf_path_or_io: io)
      expect(ingestion.status).to eq("matched")
      expect(ingestion.payment_document.attachment_filename).to eq("receipt.pdf")
    end

    it "handles custom object that responds to path and original_filename but not read/seek" do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      custom_io = double("CustomIO")
      allow(custom_io).to receive(:path).and_return(pdf_path.to_s)
      allow(custom_io).to receive(:original_filename).and_return("custom_original_name.pdf")
      allow(custom_io).to receive(:respond_to?).with(:read).and_return(false)
      allow(custom_io).to receive(:respond_to?).with(:seek).and_return(false)
      allow(custom_io).to receive(:respond_to?).with(:rewind).and_return(false)
      allow(custom_io).to receive(:respond_to?).with(:original_filename).and_return(true)
      allow(custom_io).to receive(:respond_to?).with(:path).and_return(true)

      ingestion = described_class.new.call(user: user, pdf_path_or_io: custom_io)
      expect(ingestion.status).to eq("matched")
      expect(ingestion.payment_document.attachment_filename).to eq("custom_original_name.pdf")
    end
  end

  describe "extractor fallback" do
    it "falls back to page.extract_text if smart_text_extractor task is not available" do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = described_class.new
      allow_any_instance_of(HexaPDF::Document).to receive(:task).with(:smart_text_extractor).and_raise(RuntimeError)
      ingestion = ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
      expect(ingestion.status).to eq("matched")
    end

    it "calls smart_text_extractor when it is available" do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = described_class.new
      extractor_double = double("SmartTextExtractor")
      allow(extractor_double).to receive(:text).and_return("JANE SMITH sent you money $1,300.00 Mar 24, 2026 Transaction number ZELNEW202604 zelle")
      allow_any_instance_of(HexaPDF::Document).to receive(:task).with(:smart_text_extractor).and_return(extractor_double)
      ingestion = ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
      expect(ingestion.status).to eq("matched")
    end
  end

  describe "failed result behaviors" do
    it "does not save failed parsing results for a bank statement" do
      statement_path = Rails.root.join("spec/fixtures/files/statements/20260416-statements-1234-.pdf")
      ingestion_service = described_class.new
      failed_result = double("Result", success?: false, error_message: "some error")
      success_result = double("Result", success?: true, payer_name: "Alice Smith", payer_username: nil, receipt_type: "chase_statement", amount: 1300.0, payment_date: Date.new(2026, 3, 24), payment_method: "zelle", transaction_number: "ZEL123", raw_text: "some text")

      allow_any_instance_of(PaymentIngestions::Parsers::ChaseStatement).to receive(:parse).and_return([ failed_result, success_result ])

      alice = create(:party, user: user, display_name: "Alice Smith")
      u1 = create(:rentable_unit, property: property, name: "Unit 1")
      l1 = create(:tenancy, rentable_unit: u1, agreement_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), termination_date: nil)
      create(:tenancy_party, tenancy: l1, party: alice, role: "tenant", effective_from: Date.new(2023, 1, 1))

      ingestions = ingestion_service.call(user: user, pdf_path_or_io: statement_path)
      expect(ingestions.size).to eq(1)
      expect(ingestions.first.payer_name).to eq("Alice Smith")
    end

    it "attempts to save a failed ingestion record (raising RecordInvalid) when parsing a single receipt fails" do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = described_class.new
      failed_result = double("Result", success?: false, error_message: "some parsing error")
      allow_any_instance_of(PaymentIngestions::Parsers::Zelle).to receive(:parse).and_return(failed_result)

      expect {
        ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "treats a dry Failure as failed without re-deriving status from the payload" do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = described_class.new
      failed_result = PaymentIngestions::IngestionResult.failure(
        receipt_type: "zelle",
        raw_text: "unparsed receipt"
      )
      allow_any_instance_of(PaymentIngestions::Parsers::Zelle).to receive(:parse).and_return(failed_result)

      expect {
        ingestion = ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
        expect(ingestion.status).to eq("failed")
      }.to change(PaymentIngestion, :count).by(1)
    end
  end

  describe "tenancy matching edge cases" do
    it "matches an active tenancy if the tenancy has no termination date" do
      tenant.tenancy_parties.destroy_all
      u_open = create(:rentable_unit, property: property, name: "Open Unit")
      tenancy_no_term = create(:tenancy, rentable_unit: u_open, agreement_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), termination_date: nil)
      create(:tenancy_party, tenancy: tenancy_no_term, party: tenant, role: "tenant", effective_from: Date.new(2023, 1, 1))

      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion = described_class.new.call(user: user, pdf_path_or_io: pdf_path)
      expect(ingestion.tenancy).to eq(tenancy_no_term)
    end

    it "matches the active tenancy across sequential month-to-month tenancies" do
      tenant.tenancy_parties.destroy_all
      u_past = create(:rentable_unit, property: property, name: "Past Unit")
      u_curr = create(:rentable_unit, property: property, name: "Current Unit")

      tenancy_past = create(:tenancy,
        rentable_unit: u_past,
        agreement_type: "month_to_month",
        commencement_date: Date.new(2025, 1, 1),
        termination_date: Date.new(2025, 6, 30)
      )
      create(:tenancy_party, tenancy: tenancy_past, party: tenant, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30))

      tenancy_curr = create(:tenancy,
        rentable_unit: u_curr,
        agreement_type: "month_to_month",
        commencement_date: Date.new(2025, 7, 1),
        termination_date: nil
      )
      create(:tenancy_party, tenancy: tenancy_curr, party: tenant, role: "tenant", effective_from: Date.new(2025, 7, 1), effective_until: nil)

      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion = described_class.new.call(user: user, pdf_path_or_io: pdf_path)
      expect(ingestion.tenancy).to eq(tenancy_curr)
    end

    it "marks ingestion status as ambiguous when party has multiple concurrent active tenancies" do
      tenant.tenancy_parties.destroy_all
      u1 = create(:rentable_unit, property: property, name: "Unit 1")
      u2 = create(:rentable_unit, property: property, name: "Unit 2")

      t1 = create(:tenancy,
        rentable_unit: u1,
        agreement_type: "month_to_month",
        commencement_date: Date.new(2025, 1, 1),
        termination_date: nil
      )
      create(:tenancy_party, tenancy: t1, party: tenant, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: nil)

      t2 = create(:tenancy,
        rentable_unit: u2,
        agreement_type: "month_to_month",
        commencement_date: Date.new(2025, 1, 1),
        termination_date: nil
      )
      create(:tenancy_party, tenancy: t2, party: tenant, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: nil)

      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion = described_class.new.call(user: user, pdf_path_or_io: pdf_path)

      expect(ingestion.status).to eq("ambiguous")
      expect(ingestion.tenancy).to be_nil
    end
  end

  describe "parsing error cases" do
    it "raises ParsingError for unrecognized document format" do
      doc = HexaPDF::Document.new
      doc.pages.add
      io = StringIO.new
      doc.write(io)
      io.rewind

      expect {
        described_class.new.call(user: user, pdf_path_or_io: io)
      }.to raise_error(PaymentIngestions::ParsingError, "Unrecognized document format")
    end

    it "raises ParsingError for multi-page non-statement receipt" do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = described_class.new
      allow(ingestion_service).to receive(:extract_pdf_data).and_return([
        File.binread(pdf_path),
        "202604 Zelle.pdf",
        2,
        "Transaction number ZEL123 zelle",
        PaymentDocument.new(user: user)
      ])

      expect {
        ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
      }.to raise_error(PaymentIngestions::ParsingError, "Multi-page statement PDFs are not supported")
    end

    it "raises ParsingError when payment document is missing attachment data" do
      payment_doc = build(:payment_document, user: user, attachment_file: nil)
      expect {
        described_class.new.call(user: user, pdf_path_or_io: payment_doc)
      }.to raise_error(PaymentIngestions::ParsingError, "Payment document is missing attachment data")
    end
  end
end
