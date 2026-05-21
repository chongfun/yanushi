require "test_helper"

class PaymentIngestionTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @tenant = tenants(:one)
    @lease = leases(:one)
  end

  test "should be valid with basic required fields" do
    ingestion = PaymentIngestion.new(
      user: @user,
      source: "pdf_upload",
      status: "pending"
    )
    assert ingestion.valid?
  end

  test "should be invalid without user or source or status" do
    ingestion = PaymentIngestion.new(user: nil, source: nil, status: nil)
    assert_not ingestion.valid?
  end

  test "confirmable? returns true only when required fields are present and no duplicate exists" do
    ingestion = PaymentIngestion.new(
      user: @user,
      source: "pdf_upload",
      status: "matched",
      tenant: @tenant,
      lease: @lease,
      amount: 1000.0,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "TXN123"
    )
    assert ingestion.confirmable?

    # Missing lease
    ingestion.lease = nil
    assert_not ingestion.confirmable?
    ingestion.lease = @lease

    # Missing amount
    ingestion.amount = nil
    assert_not ingestion.confirmable?
    ingestion.amount = 1000.0

    # Duplicate payment exists
    TenantPayment.create!(
      lease: @lease,
      amount: 500.0,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "TXN123"
    )
    assert_not ingestion.confirmable?
  end

  test "confirm! creates tenant payment and updates status" do
    ingestion = PaymentIngestion.create!(
      user: @user,
      source: "pdf_upload",
      status: "matched",
      tenant: @tenant,
      lease: @lease,
      amount: 1200.0,
      payment_date: Date.current,
      payment_method: "venmo",
      transaction_number: "TXN456"
    )

    assert_difference "TenantPayment.count", 1 do
      payment = ingestion.confirm!
      assert_equal 1200.0, payment.amount
      assert_equal "venmo", payment.payment_method
      assert_equal "TXN456", payment.transaction_number
      assert_equal @lease, payment.lease
    end

    assert_equal "confirmed", ingestion.reload.status
    assert_not_nil ingestion.tenant_payment
  end

  test "confirm! with create_alias: true creates alias" do
    ingestion = PaymentIngestion.create!(
      user: @user,
      source: "pdf_upload",
      status: "matched",
      tenant: @tenant,
      lease: @lease,
      amount: 1200.0,
      payment_date: Date.current,
      payment_method: "venmo",
      payer_name: "Samantha Lopez",
      payer_username: "@samlopez",
      transaction_number: "TXN789"
    )

    assert_difference "TenantAlias.count", 2 do
      ingestion.confirm!(create_alias: true)
    end

    assert @tenant.tenant_aliases.exists?(alias_name: "Samantha Lopez")
    assert @tenant.tenant_aliases.exists?(alias_name: "@samlopez")
  end

  test "confirm! rescues RecordNotUnique and raises ConfirmationError" do
    # Create a payment with same details
    TenantPayment.create!(
      lease: @lease,
      amount: 500.0,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "TXNDUP"
    )

    ingestion = PaymentIngestion.new(
      user: @user,
      source: "pdf_upload",
      status: "matched",
      tenant: @tenant,
      lease: @lease,
      amount: 1000.0,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "TXNDUP"
    )

    assert_raise PaymentIngestions::ConfirmationError do
      ingestion.confirm!
    end
  end

  test "duplicate_exists? only flags duplicates within the same user" do
    other_user = users(:two)
    other_tenant = Tenant.create!(user: other_user, name: "Other Tenant", mailing_address: "Address", email_address: "other@example.com")
    other_property = RentalProperty.create!(user: other_user, address: "456 Other Rd")
    other_lease = Lease.create!(rental_property: other_property, commencement_date: Date.current, annual_rental_amount: 1000)
    LeaseTenant.create!(lease: other_lease, tenant: other_tenant)

    # Create payment for other user
    TenantPayment.create!(
      lease: other_lease,
      amount: 1000.0,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "TXNSCOPED"
    )

    # Create ingestion for our user (user one) with the same transaction number
    ingestion = PaymentIngestion.new(
      user: @user,
      source: "pdf_upload",
      status: "matched",
      tenant: @tenant,
      lease: @lease,
      amount: 1000.0,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "TXNSCOPED"
    )

    # Since it is a different user's payment, it should NOT flag as duplicate!
    assert_not ingestion.duplicate_exists?
    assert ingestion.valid?

    # Now reassign that payment to our user's lease
    payment = TenantPayment.find_by!(transaction_number: "TXNSCOPED")
    payment.update!(lease: @lease)

    # Now it should flag as duplicate!
    assert ingestion.duplicate_exists?
    assert_not ingestion.valid?
  end

  test "supports database-backed attachment" do
    payment_doc = PaymentDocument.create!(
      user: @user,
      attachment_file: "fake receipt content",
      attachment_filename: "test.pdf",
      attachment_content_type: "application/pdf"
    )
    ingestion = PaymentIngestion.new(
      user: @user,
      source: "pdf_upload",
      status: "pending",
      payment_document: payment_doc
    )
    assert ingestion.save
    assert ingestion.attachment_attached?
    assert_equal "test.pdf", ingestion.payment_document.attachment_filename
    assert_equal "fake receipt content", ingestion.payment_document.attachment_file
  end
end
