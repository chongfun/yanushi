require "test_helper"

class PaymentIngestionsServiceTest < ActiveSupport::TestCase
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

    assert_difference "PaymentIngestion.count", 1 do
      ingestion = PaymentIngestions::Ingestion.new.call(
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

    assert_difference "PaymentIngestion.count", 1 do
      ingestion = PaymentIngestions::Ingestion.new.call(
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

    assert_difference "PaymentIngestion.count", 1 do
      ingestion = PaymentIngestions::Ingestion.new.call(
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

    ingestion = PaymentIngestions::Ingestion.new.call(
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

    ingestion = PaymentIngestions::Ingestion.new.call(
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

    ingestion = PaymentIngestions::Ingestion.new.call(
      user: @user,
      pdf_path_or_io: pdf_path,
      source: "pdf_upload"
    )

    assert_equal "ambiguous", ingestion.status
    assert_nil ingestion.tenant
  end

  test "ingests multi-page bank statement and creates ingestion records for matched names" do
    # Create tenants matching the statement
    alice = Tenant.create!(user: @user, name: "Alice Smith", mailing_address: "Addr", email_address: "alice@example.com")
    charlie = Tenant.create!(user: @user, name: "Charlie Brown", mailing_address: "Addr", email_address: "charlie@example.com")
    bob = Tenant.create!(user: @user, name: "Bob Jones", mailing_address: "Addr", email_address: "bob@example.com")

    # Link them to leases
    l1 = Lease.create!(rental_property: rental_properties(:one), lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0)
    LeaseTenant.create!(lease: l1, tenant: alice)

    l2 = Lease.create!(rental_property: rental_properties(:one), lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0)
    LeaseTenant.create!(lease: l2, tenant: charlie)

    l3 = Lease.create!(rental_property: rental_properties(:one), lease_type: "month_to_month", commencement_date: Date.new(2023, 1, 1), annual_rental_amount: 12000.0)
    LeaseTenant.create!(lease: l3, tenant: bob)

    statement_path = Rails.root.join("test/fixtures/files/statements/20260416-statements-1234-.pdf")

    assert_difference "PaymentIngestion.count", 3 do
      ingestions = PaymentIngestions::Ingestion.new.call(
        user: @user,
        pdf_path_or_io: statement_path,
        source: "pdf_upload"
      )

      assert_equal 3, ingestions.size

      # Verify details of one ingestion
      ing_alice = ingestions.find { |i| i.payer_name == "Alice Smith" }
      assert_not_nil ing_alice
      assert_equal "chase_statement", ing_alice.receipt_type
      assert_equal "matched", ing_alice.status
      assert_equal BigDecimal("1300.00"), ing_alice.amount
      assert_equal Date.new(2026, 3, 24), ing_alice.payment_date
      assert_equal "ZELNEW202604A", ing_alice.transaction_number
      assert_equal alice, ing_alice.tenant
      assert_equal l1, ing_alice.lease

      # Verify they all share the same payment document
      doc = ing_alice.payment_document
      assert_not_nil doc
      assert_equal "20260416-statements-1234-.pdf", doc.attachment_filename
      assert_equal "application/pdf", doc.attachment_content_type
      assert_equal 3, doc.payment_ingestions.count
    end
  end
end
