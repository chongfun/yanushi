require "test_helper"

class PaymentIngestionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    sign_in_as(@user)

    # Create a basic ingestion record for show/update/confirm/delete tests
    @document = PaymentDocument.create!(
      user: @user,
      attachment_file: "dummy_pdf_content",
      attachment_filename: "receipt.pdf",
      attachment_content_type: "application/pdf",
      status: :success
    )

    @ingestion = PaymentIngestion.create!(
      user: @user,
      source: "pdf_upload",
      status: "matched",
      payer_name: "Jane Doe",
      amount: 1300.0,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "TXNTEST123",
      tenant: tenants(:one),
      lease: leases(:one),
      payment_document: @document
    )
  end

  test "should get index" do
    get payment_ingestions_url
    assert_response :success
    assert_select "h1", "Payment Ingestion"
  end

  test "should get new" do
    get new_payment_ingestion_url
    assert_response :success
  end

  test "should create payment ingestion" do
    pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")

    assert_difference("PaymentIngestion.count", 1) do
      perform_enqueued_jobs do
        post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
      end
    end

    new_ingestion = PaymentIngestion.last
    assert_redirected_to payment_ingestions_url
    assert_equal "zelle", new_ingestion.receipt_type
    assert_equal "success", PaymentDocument.last.status
  end

  test "should not create duplicate payment ingestion and should show friendly message" do
    pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")

    perform_enqueued_jobs do
      post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
    end

    assert_no_difference("PaymentIngestion.count") do
      perform_enqueued_jobs do
        post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
      end
    end

    assert_redirected_to payment_ingestions_url
    failed_doc = PaymentDocument.last
    assert_equal "failed", failed_doc.status
    assert_match /This payment receipt has already been uploaded/, failed_doc.error_message
  end

  test "should show payment ingestion" do
    get payment_ingestion_url(@ingestion)
    assert_response :success
  end

  test "should update payment ingestion" do
    patch payment_ingestion_url(@ingestion), params: {
      payment_ingestion: {
        amount: 1400.0,
        payment_method: "venmo"
      }
    }
    assert_redirected_to payment_ingestion_url(@ingestion)
    assert_equal 1400.0, @ingestion.reload.amount
    assert_equal "venmo", @ingestion.payment_method
  end

  test "should download payment attachment" do
    get download_payment_ingestion_url(@ingestion)
    assert_response :success
    assert_equal "dummy_pdf_content", response.body
  end

  test "should confirm payment ingestion" do
    assert_difference("TenantPayment.count", 1) do
      post confirm_payment_ingestion_url(@ingestion), params: { create_alias: "0" }
    end
    assert_redirected_to payment_ingestions_url
    assert_equal "confirmed", @ingestion.reload.status
  end

  test "should destroy payment ingestion" do
    assert_difference("PaymentIngestion.count", -1) do
      delete payment_ingestion_url(@ingestion)
    end
    assert_redirected_to payment_ingestions_url
  end

  test "should create multiple payment ingestions when uploading a bank statement" do
    # Create matching tenants for statement parsing
    alice = Tenant.create!(user: @user, name: "Alice Smith", mailing_address: "Addr", email_address: "alice@example.com")
    l1 = Lease.create!(rental_property: rental_properties(:one), lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0)
    LeaseTenant.create!(lease: l1, tenant: alice)

    pdf_file = fixture_file_upload("statements/20260416-statements-1234-.pdf", "application/pdf")

    assert_difference("PaymentIngestion.count", 1) do # only Alice Smith is matched because we only created her tenant
      perform_enqueued_jobs do
        post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
      end
    end

    assert_redirected_to payment_ingestions_url
    assert_equal "success", PaymentDocument.last.status
  end

  test "should return error if statement uploaded but no matching tenants found" do
    pdf_file = fixture_file_upload("statements/20260416-statements-1234-.pdf", "application/pdf")

    assert_no_difference("PaymentIngestion.count") do
      perform_enqueued_jobs do
        post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
      end
    end

    assert_redirected_to payment_ingestions_url
    failed_doc = PaymentDocument.last
    assert_equal "failed", failed_doc.status
    assert_match /No matching tenant transactions found/, failed_doc.error_message
  end

  test "should reject uploads with invalid content type" do
    # Create a temporary non-PDF file (plain text, not starting with %PDF-)
    text_file = Rack::Test::UploadedFile.new(
      StringIO.new("This is just a plain text file, not a PDF."),
      "application/pdf",
      false,
      original_filename: "not_a_pdf.pdf"
    )

    assert_no_difference("PaymentDocument.count") do
      post payment_ingestions_url, params: { payment_ingestion: { pdf_file: text_file } }
    end

    assert_redirected_to new_payment_ingestion_url
    assert_equal "Only PDF files are supported.", flash[:alert]
  end

  test "should reject uploads that exceed file size limit" do
    pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")

    ActionDispatch::Http::UploadedFile.class_eval do
      alias_method :original_size, :size
      def size
        11.megabytes
      end
    end

    begin
      assert_no_difference("PaymentDocument.count") do
        post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
      end
    ensure
      ActionDispatch::Http::UploadedFile.class_eval do
        alias_method :size, :original_size
        remove_method :original_size
      end
    end

    assert_redirected_to new_payment_ingestion_url
    assert_equal "File size exceeds the 10MB limit.", flash[:alert]
  end

  test "should paginate confirmed ingestions on index page" do
    # Create 22 confirmed ingestions
    22.times do |i|
      PaymentIngestion.create!(
        user: @user,
        source: "pdf_upload",
        status: "confirmed",
        payer_name: "Jane Doe #{i}",
        amount: 100.0,
        payment_date: Date.current,
        payment_method: "zelle",
        transaction_number: "TXNPAG#{i}",
        payment_document: @document
      )
    end

    get payment_ingestions_url
    assert_response :success
    # Should only show 20 confirmed ingestions in history table (table-sm)
    assert_select "table.table-sm tbody tr", count: 20

    get payment_ingestions_url, params: { page: 2 }
    assert_response :success
    # Page 2 should show the remaining 2 confirmed ingestions
    assert_select "table.table-sm tbody tr", count: 2
  end
end
