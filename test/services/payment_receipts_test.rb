require "test_helper"

class PaymentReceiptsTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @user.update!(timezone: "Pacific Time (US & Canada)")

    # Clean existing tenants to avoid interference
    @user.tenants.destroy_all

    @tenant = Tenant.create!(
      user: @user,
      name: "Jane Smith",
      mailing_address: "123 Main St",
      phone_number: "555-1234",
      email_address: "jane@example.com"
    )

    @lease = Lease.create!(
      rental_property: rental_properties(:one),
      lease_type: "term",
      commencement_date: Date.new(2023, 1, 1),
      termination_date: Date.new(2028, 12, 31),
      annual_rental_amount: 12000.0,
      late_period_days: 5
    )
    # Link tenant to lease
    LeaseTenant.create!(lease: @lease, tenant: @tenant)
  end

  test "ingests Chase Zelle 202604 receipt PDF correctly" do
    pdf_path = Rails.root.join("test/fixtures/files/receipts/202604 Zelle.pdf")

    assert_difference "PaymentReceiptIngestion.count", 1 do
      ingestion = PaymentReceipts::Ingestion.new.call(
        user: @user,
        pdf_path_or_io: pdf_path,
        source: "pdf_upload"
      )

      assert ingestion.persisted?
      assert_equal "zelle", ingestion.receipt_type
      assert_equal "matched", ingestion.status
      assert_equal "JANE SMITH", ingestion.payer_name
      assert_nil ingestion.payer_username
      assert_equal BigDecimal("1300.00"), ingestion.amount
      assert_equal Date.new(2026, 3, 24), ingestion.payment_date
      assert_equal "ZELNEW202604", ingestion.transaction_number
      assert_equal @tenant, ingestion.tenant
      assert_equal @lease, ingestion.lease
      assert ingestion.attachment_attached?
    end
  end

  test "ingests Chase Zelle 202312 receipt PDF correctly" do
    pdf_path = Rails.root.join("test/fixtures/files/receipts/202312 Security Deposit Zelle.pdf")

    assert_difference "PaymentReceiptIngestion.count", 1 do
      ingestion = PaymentReceipts::Ingestion.new.call(
        user: @user,
        pdf_path_or_io: pdf_path,
        source: "pdf_upload"
      )

      assert ingestion.persisted?
      assert_equal "zelle", ingestion.receipt_type
      assert_equal "matched", ingestion.status
      assert_equal "JANE SMITH", ingestion.payer_name
      assert_nil ingestion.payer_username
      assert_equal BigDecimal("1950.00"), ingestion.amount
      assert_equal Date.new(2023, 12, 4), ingestion.payment_date
      assert_equal "ZELNEW202312", ingestion.transaction_number
      assert_equal @tenant, ingestion.tenant
      assert_equal @lease, ingestion.lease
    end
  end

  test "ingests Venmo 202403 receipt PDF correctly" do
    pdf_path = Rails.root.join("test/fixtures/files/receipts/202403 Venmo.pdf")

    assert_difference "PaymentReceiptIngestion.count", 1 do
      ingestion = PaymentReceipts::Ingestion.new.call(
        user: @user,
        pdf_path_or_io: pdf_path,
        source: "pdf_upload"
      )

      assert ingestion.persisted?
      assert_equal "venmo", ingestion.receipt_type
      assert_equal "matched", ingestion.status
      assert_equal "jane smith", ingestion.payer_name
      assert_equal "@janesmith", ingestion.payer_username
      assert_equal BigDecimal("1000.00"), ingestion.amount
      assert_equal Date.new(2024, 3, 1), ingestion.payment_date
      assert_equal "9991209384910283", ingestion.transaction_number
      assert_equal @tenant, ingestion.tenant
      assert_equal @lease, ingestion.lease
    end
  end

  test "resolves tenant by alias when display name does not match" do
    # Change tenant name so display name won't match, and add alias for username
    @tenant.update!(name: "Jane S. Smith")
    TenantAlias.create!(tenant: @tenant, alias_name: "@janesmith")

    pdf_path = Rails.root.join("test/fixtures/files/receipts/202403 Venmo.pdf")

    ingestion = PaymentReceipts::Ingestion.new.call(
      user: @user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    assert_equal "matched", ingestion.status
    assert_equal @tenant, ingestion.tenant
  end

  test "resolves status to unmatched when no tenant matches" do
    @tenant.update!(name: "Someone Else")
    pdf_path = Rails.root.join("test/fixtures/files/receipts/202604 Zelle.pdf")

    ingestion = PaymentReceipts::Ingestion.new.call(
      user: @user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    assert_equal "unmatched", ingestion.status
    assert_nil ingestion.tenant
  end

  test "resolves status to ambiguous when multiple tenants match display name or alias" do
    # Create another tenant named "Jane Smith"
    Tenant.create!(
      user: @user,
      name: "Jane Smith",
      mailing_address: "456 Side St",
      phone_number: "555-9999",
      email_address: "jane2@example.com"
    )

    pdf_path = Rails.root.join("test/fixtures/files/receipts/202604 Zelle.pdf")

    ingestion = PaymentReceipts::Ingestion.new.call(
      user: @user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    assert_equal "ambiguous", ingestion.status
    assert_nil ingestion.tenant
  end
end
