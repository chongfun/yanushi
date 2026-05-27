require 'rails_helper'

RSpec.describe PaymentIngestions::Ingestion do
  let(:user) { create(:user, timezone: "Pacific Time (US & Canada)") }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) do
    create(:lease,
      rental_property: property,
      lease_type: "term",
      commencement_date: Date.new(2023, 1, 1),
      termination_date: Date.new(2028, 12, 31),
      annual_rental_amount: 12000.0,
      late_period_days: 5
    )
  end
  let!(:tenant) { create(:tenant, user: user, name: "Jane Smith") }

  before do
    # Link tenant to lease
    create(:lease_tenant, lease: lease, tenant: tenant)
  end

  it 'ingests Chase Zelle 202604 receipt PDF correctly' do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")

    expect {
      ingestion = PaymentIngestions::Ingestion.new.call(
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
      expect(ingestion.tenant).to eq(tenant)
      expect(ingestion.lease).to eq(lease)
      expect(ingestion.attachment_attached?).to be_truthy
    }.to change(PaymentIngestion, :count).by(1)
  end

  it 'ingests Chase Zelle 202312 receipt PDF correctly' do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202312 Security Deposit Zelle.pdf")

    expect {
      ingestion = PaymentIngestions::Ingestion.new.call(
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
      expect(ingestion.tenant).to eq(tenant)
      expect(ingestion.lease).to eq(lease)
    }.to change(PaymentIngestion, :count).by(1)
  end

  it 'ingests Venmo 202403 receipt PDF correctly' do
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202403 Venmo.pdf")

    expect {
      ingestion = PaymentIngestions::Ingestion.new.call(
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
      expect(ingestion.tenant).to eq(tenant)
      expect(ingestion.lease).to eq(lease)
    }.to change(PaymentIngestion, :count).by(1)
  end

  it 'resolves tenant by alias when display name does not match' do
    tenant.update!(name: "Jane S. Smith")
    create(:tenant_alias, tenant: tenant, alias_name: "@janesmith")

    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202403 Venmo.pdf")

    ingestion = PaymentIngestions::Ingestion.new.call(
      user: user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    expect(ingestion.status).to eq("matched")
    expect(ingestion.tenant).to eq(tenant)
  end

  it 'resolves status to unmatched when no tenant matches' do
    tenant.update!(name: "Someone Else")
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")

    ingestion = PaymentIngestions::Ingestion.new.call(
      user: user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    expect(ingestion.status).to eq("unmatched")
    expect(ingestion.tenant).to be_nil
  end

  it 'resolves status to ambiguous when multiple tenants match display name or alias' do
    create(:tenant, user: user, name: "Jane Smith")
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")

    ingestion = PaymentIngestions::Ingestion.new.call(
      user: user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    expect(ingestion.status).to eq("ambiguous")
    expect(ingestion.tenant).to be_nil
  end

  it 'ingests multi-page bank statement and creates ingestion records for matched names' do
    # Cleanup main tenant to avoid conflicts
    tenant.destroy!

    alice = create(:tenant, user: user, name: "Alice Smith")
    charlie = create(:tenant, user: user, name: "Charlie Brown")
    bob = create(:tenant, user: user, name: "Bob Jones")

    l1 = create(:lease, rental_property: property, lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0)
    create(:lease_tenant, lease: l1, tenant: alice)

    l2 = create(:lease, rental_property: property, lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0)
    create(:lease_tenant, lease: l2, tenant: charlie)

    l3 = create(:lease, rental_property: property, lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0)
    create(:lease_tenant, lease: l3, tenant: bob)

    statement_path = Rails.root.join("spec/fixtures/files/statements/20260416-statements-1234-.pdf")

    expect {
      ingestions = PaymentIngestions::Ingestion.new.call(
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
      expect(ing_alice.tenant).to eq(alice)
      expect(ing_alice.lease).to eq(l1)

      doc = ing_alice.payment_document
      expect(doc).not_to be_nil
      expect(doc.attachment_filename).to eq("20260416-statements-1234-.pdf")
      expect(doc.attachment_content_type).to eq("application/pdf")
      expect(doc.payment_ingestions.count).to eq(3)
    }.to change(PaymentIngestion, :count).by(3)
  end

  describe 'parser name patterns and parsing exceptions' do
    it 'extracts payer names with Unicode, apostrophes, and hyphens' do
      text_column = "Completed\nRené O'Connor-Smith\nIn moments\n$1,300.00\nTransaction number ZELNEW202604\nDec 4, 2023"
      result1 = PaymentIngestions::Parsers::Zelle.new.parse(text_column)
      expect(result1.success?).to be_truthy
      expect(result1.payer_name).to eq("René O'Connor-Smith")
      expect(result1.amount).to eq(BigDecimal("1300.00"))
      expect(result1.payment_date).to eq(Date.new(2023, 12, 4))
      expect(result1.transaction_number).to eq("ZELNEW202604")

      text_sentence = "René O'Connor-Smith sent you money\n$1,300.00\nTransaction number ZELNEW202604\nDec 4, 2023"
      result2 = PaymentIngestions::Parsers::Zelle.new.parse(text_sentence)
      expect(result2.success?).to be_truthy
      expect(result2.payer_name).to eq("René O'Connor-Smith")
    end

    it 'parsers handle exceptions gracefully and return failure result' do
      result_zelle = PaymentIngestions::Parsers::Zelle.new.parse(nil)
      expect(result_zelle.success?).to be_falsey
      expect(result_zelle.error_message).to match(/undefined method/)

      result_venmo = PaymentIngestions::Parsers::Venmo.new.parse(nil)
      expect(result_venmo.success?).to be_falsey
      expect(result_venmo.error_message).to match(/undefined method/)

      result_chase = PaymentIngestions::Parsers::ChaseStatement.new.parse(nil)
      expect(result_chase.size).to eq(1)
      expect(result_chase.first.success?).to be_falsey
      expect(result_chase.first.error_message).to match(/undefined method/)
    end
  end

  describe 'parsing error conditions and format validations' do
    it 'raises ParsingError when document format is unrecognized' do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = PaymentIngestions::Ingestion.new
      allow(ingestion_service).to receive(:extract_pdf_data).and_return([
        "dummy_bytes", "receipt.pdf", 1, "some unrecognized pdf text that has no match", PaymentDocument.new
      ])
      expect {
        ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
      }.to raise_error(PaymentIngestions::ParsingError, "Unrecognized document format")
    end

    it 'raises ParsingError when non-statement PDF has multiple pages' do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = PaymentIngestions::Ingestion.new
      allow(ingestion_service).to receive(:detect_type).and_return("zelle")
      allow(ingestion_service).to receive(:extract_pdf_data).and_return([
        "dummy_bytes", "receipt.pdf", 2, "zelle text", PaymentDocument.new
      ])
      expect {
        ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
      }.to raise_error(PaymentIngestions::ParsingError, "Multi-page statement PDFs are not supported")
    end
  end

  describe 'extract_pdf_data with PaymentDocument' do
    it 'uses attachment_file directly when the attribute is loaded' do
      payment_doc = create(:payment_document, user: user, attachment_file: File.binread(Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")))
      ingestion_service = PaymentIngestions::Ingestion.new
      expect(PaymentDocument).not_to receive(:where)
      ingestion_service.call(user: user, pdf_path_or_io: payment_doc)
    end

    it 'queries the database for attachment_file when the attribute is not loaded' do
      payment_doc = create(:payment_document, user: user, attachment_file: File.binread(Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")))
      doc_without_blob = PaymentDocument.select(:id, :user_id, :attachment_filename, :attachment_content_type, :status).find(payment_doc.id)
      ingestion_service = PaymentIngestions::Ingestion.new
      ingestion = ingestion_service.call(user: user, pdf_path_or_io: doc_without_blob)
      expect(ingestion.status).to eq("matched")
    end
  end

  describe 'handles different io-like and file types' do
    it 'handles IO-like object that responds to read and seek' do
      File.open(Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf"), "rb") do |file|
        ingestion = PaymentIngestions::Ingestion.new.call(user: user, pdf_path_or_io: file)
        expect(ingestion.status).to eq("matched")
      end
    end

    it 'handles string file paths' do
      pdf_path_str = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf").to_s
      ingestion = PaymentIngestions::Ingestion.new.call(user: user, pdf_path_or_io: pdf_path_str)
      expect(ingestion.status).to eq("matched")
    end

    it 'handles StringIO objects and triggers fallback filename' do
      pdf_data = File.binread(Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf"))
      io = StringIO.new(pdf_data)
      ingestion = PaymentIngestions::Ingestion.new.call(user: user, pdf_path_or_io: io)
      expect(ingestion.status).to eq("matched")
      expect(ingestion.payment_document.attachment_filename).to eq("receipt.pdf")
    end

    it 'handles custom object that responds to path and original_filename but not read/seek' do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      custom_io = double("CustomIO")
      allow(custom_io).to receive(:path).and_return(pdf_path.to_s)
      allow(custom_io).to receive(:original_filename).and_return("custom_original_name.pdf")
      allow(custom_io).to receive(:respond_to?).with(:read).and_return(false)
      allow(custom_io).to receive(:respond_to?).with(:seek).and_return(false)
      allow(custom_io).to receive(:respond_to?).with(:rewind).and_return(false)
      allow(custom_io).to receive(:respond_to?).with(:original_filename).and_return(true)
      allow(custom_io).to receive(:respond_to?).with(:path).and_return(true)

      ingestion = PaymentIngestions::Ingestion.new.call(user: user, pdf_path_or_io: custom_io)
      expect(ingestion.status).to eq("matched")
      expect(ingestion.payment_document.attachment_filename).to eq("custom_original_name.pdf")
    end
  end

  describe 'extractor fallback' do
    it 'falls back to page.extract_text if smart_text_extractor task is not available' do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = PaymentIngestions::Ingestion.new
      allow_any_instance_of(HexaPDF::Document).to receive(:task).with(:smart_text_extractor).and_raise(RuntimeError)
      ingestion = ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
      expect(ingestion.status).to eq("matched")
    end

    it 'calls smart_text_extractor when it is available' do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = PaymentIngestions::Ingestion.new
      extractor_double = double("SmartTextExtractor")
      allow(extractor_double).to receive(:text).and_return("JANE SMITH sent you money $1,300.00 Mar 24, 2026 Transaction number ZELNEW202604 zelle")
      allow_any_instance_of(HexaPDF::Document).to receive(:task).with(:smart_text_extractor).and_return(extractor_double)
      ingestion = ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
      expect(ingestion.status).to eq("matched")
    end
  end

  describe 'failed result behaviors' do
    it 'does not save failed parsing results for a bank statement' do
      statement_path = Rails.root.join("spec/fixtures/files/statements/20260416-statements-1234-.pdf")
      ingestion_service = PaymentIngestions::Ingestion.new
      failed_result = double("Result", success?: false, error_message: "some error")
      success_result = double("Result", success?: true, payer_name: "Alice Smith", payer_username: nil, receipt_type: "chase_statement", amount: 1300.0, payment_date: Date.new(2026, 3, 24), payment_method: "zelle", transaction_number: "ZEL123", raw_text: "some text")

      allow_any_instance_of(PaymentIngestions::Parsers::ChaseStatement).to receive(:parse).and_return([ failed_result, success_result ])

      alice = create(:tenant, user: user, name: "Alice Smith")
      l1 = create(:lease, rental_property: property, lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0)
      create(:lease_tenant, lease: l1, tenant: alice)

      ingestions = ingestion_service.call(user: user, pdf_path_or_io: statement_path)
      expect(ingestions.size).to eq(1)
      expect(ingestions.first.payer_name).to eq("Alice Smith")
    end

    it 'attempts to save a failed ingestion record (raising RecordInvalid) when parsing a single receipt fails' do
      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion_service = PaymentIngestions::Ingestion.new
      failed_result = double("Result", success?: false, error_message: "some parsing error")
      allow_any_instance_of(PaymentIngestions::Parsers::Zelle).to receive(:parse).and_return(failed_result)

      expect {
        ingestion_service.call(user: user, pdf_path_or_io: pdf_path)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe 'lease matching edge cases' do
    it 'matches an active lease if the lease has no termination date' do
      tenant.lease_tenants.destroy_all
      lease_no_term = create(:lease, rental_property: property, lease_type: "term", commencement_date: Date.new(2023, 1, 1), termination_date: nil, annual_rental_amount: 12000.0)
      create(:lease_tenant, lease: lease_no_term, tenant: tenant)

      pdf_path = Rails.root.join("spec/fixtures/files/receipts/202604 Zelle.pdf")
      ingestion = PaymentIngestions::Ingestion.new.call(user: user, pdf_path_or_io: pdf_path)
      expect(ingestion.lease).to eq(lease_no_term)
    end
  end
end
