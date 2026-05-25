require "test_helper"

class IngestPaymentDocumentJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    # Create tenant and lease for resolving Zelle receipt
    @tenant = Tenant.create!(user: @user, name: "Jane Smith", mailing_address: "Address", email_address: "jane.smith@example.com")
    @lease = Lease.create!(rental_property: rental_properties(:one), lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0)
    LeaseTenant.create!(lease: @lease, tenant: @tenant)
  end

  test "performs successfully for valid pdf" do
    pdf_path = Rails.root.join("test/fixtures/files/receipts/202604 Zelle.pdf")
    pdf_bytes = File.binread(pdf_path)

    doc = PaymentDocument.create!(
      user: @user,
      attachment_file: pdf_bytes,
      attachment_filename: "202604 Zelle.pdf",
      attachment_content_type: "application/pdf",
      status: :processing
    )

    assert_difference "PaymentIngestion.count", 1 do
      IngestPaymentDocumentJob.perform_now(doc.id)
    end

    doc.reload
    assert_equal "success", doc.status
    assert_nil doc.error_message

    ingestion = PaymentIngestion.last
    assert_equal "zelle", ingestion.receipt_type
    assert_equal @tenant, ingestion.tenant
    assert_equal @lease, ingestion.lease
  end

  test "fails and updates document on invalid document structure" do
    doc = PaymentDocument.create!(
      user: @user,
      attachment_file: "invalid pdf data",
      attachment_filename: "invalid.pdf",
      attachment_content_type: "application/pdf",
      status: :processing
    )

    assert_no_difference "PaymentIngestion.count" do
      IngestPaymentDocumentJob.perform_now(doc.id)
    end

    doc.reload
    assert_equal "failed", doc.status
    assert_not_nil doc.error_message
  end

  test "transaction rolls back all ingestion creation on parsing failure" do
    pdf_path = Rails.root.join("test/fixtures/files/receipts/202604 Zelle.pdf")
    pdf_bytes = File.binread(pdf_path)

    doc = PaymentDocument.create!(
      user: @user,
      attachment_file: pdf_bytes,
      attachment_filename: "202604 Zelle.pdf",
      attachment_content_type: "application/pdf",
      status: :processing
    )

    PaymentIngestions::TenantResolver.class_eval do
      alias_method :original_resolve, :resolve
      def resolve(*args)
        raise "Forced resolve error"
      end
    end

    begin
      assert_no_difference "PaymentIngestion.count" do
        IngestPaymentDocumentJob.perform_now(doc.id)
      end
    ensure
      PaymentIngestions::TenantResolver.class_eval do
        alias_method :resolve, :original_resolve
        remove_method :original_resolve
      end
    end

    doc.reload
    assert_equal "failed", doc.status
    assert_equal "Forced resolve error", doc.error_message
  end
end
