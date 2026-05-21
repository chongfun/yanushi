require "test_helper"

class PaymentIngestionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)

    # Create a basic ingestion record for show/update/confirm/delete tests
    @document = PaymentDocument.create!(
      user: @user,
      attachment_file: "dummy_pdf_content",
      attachment_filename: "receipt.pdf",
      attachment_content_type: "application/pdf"
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
      post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
    end

    new_ingestion = PaymentIngestion.last
    assert_redirected_to payment_ingestion_url(new_ingestion)
    assert_equal "zelle", new_ingestion.receipt_type
  end

  test "should not create duplicate payment ingestion and should show friendly message" do
    pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
    post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }

    assert_no_difference("PaymentIngestion.count") do
      post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
    end

    assert_redirected_to new_payment_ingestion_url
    assert_equal "This payment receipt has already been uploaded and is pending review.", flash[:alert]
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
      post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
    end

    assert_redirected_to payment_ingestions_url
    assert_match /Bank statement parsed successfully/, flash[:notice]
  end

  test "should return error if statement uploaded but no matching tenants found" do
    pdf_file = fixture_file_upload("statements/20260416-statements-1234-.pdf", "application/pdf")

    assert_no_difference("PaymentIngestion.count") do
      post payment_ingestions_url, params: { payment_ingestion: { pdf_file: pdf_file } }
    end

    assert_redirected_to payment_ingestions_url
    assert_match /but no matching tenant transactions were found/, flash[:alert]
  end
end
