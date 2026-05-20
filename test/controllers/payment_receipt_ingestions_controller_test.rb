require "test_helper"

class PaymentReceiptIngestionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)

    # Create a basic ingestion record for show/update/confirm/delete tests
    @ingestion = PaymentReceiptIngestion.create!(
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
      attachment_file: "dummy_pdf_content",
      attachment_filename: "receipt.pdf",
      attachment_content_type: "application/pdf"
    )
  end

  test "should get index" do
    get payment_receipt_ingestions_url
    assert_response :success
    assert_select "h1", "Payment Receipt Ingestion"
  end

  test "should get new" do
    get new_payment_receipt_ingestion_url
    assert_response :success
  end

  test "should create payment receipt ingestion" do
    pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")

    assert_difference("PaymentReceiptIngestion.count", 1) do
      post payment_receipt_ingestions_url, params: { payment_receipt_ingestion: { pdf_file: pdf_file } }
    end

    new_ingestion = PaymentReceiptIngestion.last
    assert_redirected_to payment_receipt_ingestion_url(new_ingestion)
    assert_equal "zelle", new_ingestion.receipt_type
  end

  test "should not create duplicate payment receipt ingestion and should show friendly message" do
    pdf_file = fixture_file_upload("receipts/202604 Zelle.pdf", "application/pdf")
    post payment_receipt_ingestions_url, params: { payment_receipt_ingestion: { pdf_file: pdf_file } }

    assert_no_difference("PaymentReceiptIngestion.count") do
      post payment_receipt_ingestions_url, params: { payment_receipt_ingestion: { pdf_file: pdf_file } }
    end

    assert_redirected_to new_payment_receipt_ingestion_url
    assert_equal "This payment receipt has already been uploaded and is pending review.", flash[:alert]
  end

  test "should show payment receipt ingestion" do
    get payment_receipt_ingestion_url(@ingestion)
    assert_response :success
  end

  test "should update payment receipt ingestion" do
    patch payment_receipt_ingestion_url(@ingestion), params: {
      payment_receipt_ingestion: {
        amount: 1400.0,
        payment_method: "venmo"
      }
    }
    assert_redirected_to payment_receipt_ingestion_url(@ingestion)
    assert_equal 1400.0, @ingestion.reload.amount
    assert_equal "venmo", @ingestion.payment_method
  end

  test "should download payment receipt attachment" do
    get download_payment_receipt_ingestion_url(@ingestion)
    assert_response :success
    assert_equal "dummy_pdf_content", response.body
  end

  test "should confirm payment receipt ingestion" do
    assert_difference("TenantPayment.count", 1) do
      post confirm_payment_receipt_ingestion_url(@ingestion), params: { create_alias: "0" }
    end
    assert_redirected_to payment_receipt_ingestions_url
    assert_equal "confirmed", @ingestion.reload.status
  end

  test "should destroy payment receipt ingestion" do
    assert_difference("PaymentReceiptIngestion.count", -1) do
      delete payment_receipt_ingestion_url(@ingestion)
    end
    assert_redirected_to payment_receipt_ingestions_url
  end
end
