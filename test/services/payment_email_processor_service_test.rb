require "test_helper"
require "mail"

class PaymentEmailProcessorServiceTest < ActiveSupport::TestCase
  setup do
    travel_to Date.parse("2024-08-01")
    @user = users(:one)

    # 1. Create a tenant named "Kristina Page"
    @tenant = Tenant.create!(
      user: @user,
      name: "Kristina Page",
      email_address: "kristina@example.com",
      mailing_address: "123 Main St",
      phone_number: "555-1234"
    )

    # 2. Add an alias "KRISTINA M PAGE" to match the Zelle emails
    @tenant.tenant_aliases.create!(name: "KRISTINA M PAGE")

    # 3. Create a rental property
    @property = RentalProperty.create!(
      user: @user,
      address: "123 Main St",
      property_type: 1, # Residential
      square_footage: 1500
    )

    # 4. Create a lease
    @lease = Lease.create!(
      rental_property: @property,
      commencement_date: Date.parse("2024-01-01"),
      termination_date: Date.parse("2024-12-31"),
      annual_rental_amount: 14400.0,
      security_deposit: 1200.0,
      lease_type: 1
    )

    # 5. Link Tenant to Lease
    LeaseTenant.create!(lease: @lease, tenant: @tenant)

    # 6. Create utility expense on the property (exactly $240.92, category: "utilities")
    @utility_expense = Expense.create!(
      rental_property: @property,
      amount: 240.92,
      category: "utilities",
      expense_date: Date.parse("2024-08-01"),
      description: "August 2024 Utilities"
    )
  end

  def read_eml_fixture(filename)
    File.read(Rails.root.join("test/fixtures/emails", filename))
  end

  test "routes Chase Zelle utility payment to lease as tenant payment" do
    raw_source = read_eml_fixture("zelle-utility-payment.eml")

    assert_difference -> { TenantPayment.count } => 1 do
      processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
      email_record = processor.call

      assert_equal "matched", email_record.status
      assert_not_nil email_record.tenant_payment
      assert_equal @lease.id, email_record.tenant_payment.lease_id
      assert_equal BigDecimal("240.92"), email_record.tenant_payment.amount
    end
  end

  test "routes Chase Zelle rent payment to lease as tenant payment" do
    raw_source = read_eml_fixture("zelle-rent-payment.eml")

    assert_difference -> { TenantPayment.count } => 1 do
      processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
      email_record = processor.call

      assert_equal "matched", email_record.status
      assert_not_nil email_record.tenant_payment
      assert_equal @lease.id, email_record.tenant_payment.lease_id
      assert_equal BigDecimal("1200.00"), email_record.tenant_payment.amount
    end
  end

  test "routes Venmo rent payment to lease using Samantha Sanchez alias" do
    # Add Samantha Sanchez alias to the tenant
    @tenant.tenant_aliases.create!(name: "samantha sanchez")
    raw_source = read_eml_fixture("venmo-rent-payment.eml")

    assert_difference -> { TenantPayment.count } => 1 do
      processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
      email_record = processor.call

      assert_equal "matched", email_record.status
      assert_not_nil email_record.tenant_payment
      assert_equal @lease.id, email_record.tenant_payment.lease_id
      assert_equal BigDecimal("1000.00"), email_record.tenant_payment.amount
    end
  end

  test "marks email unmatched and creates in-app notification when tenant cannot be found" do
    raw_source = read_eml_fixture("venmo-rent-payment.eml") # No tenant "samantha sanchez" exists

    assert_no_difference -> { TenantPayment.count } do
      assert_difference -> { Notification.count } => 1 do
        processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
        email_record = processor.call

        assert_equal "unmatched", email_record.status
        assert_nil email_record.tenant_payment
        assert_match(/No tenant found matching/i, email_record.error_message)

        notification = Notification.last
        assert_equal @user.id, notification.user_id
        assert_equal "payment_unmatched", notification.notification_type
        assert_match(/samantha sanchez/i, notification.message)
      end
    end
  end

  test "prevents double processing (deduplication)" do
    raw_source = read_eml_fixture("zelle-rent-payment.eml")

    processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
    email_record = processor.call
    assert_equal "matched", email_record.status

    # Process again - should skip/be nil
    assert_no_difference -> { TenantPayment.count } do
      second_record = processor.call
      assert_nil second_record
    end
  end

  test "prefers the active lease with the most negative balance" do
    # Create a second active lease for this tenant on a different property
    other_property = RentalProperty.create!(
      user: @user,
      address: "456 Oak St",
      property_type: 1,
      square_footage: 1000
    )
    other_lease = Lease.create!(
      rental_property: other_property,
      commencement_date: Date.parse("2024-01-01"),
      termination_date: Date.parse("2024-12-31"),
      annual_rental_amount: 6000.0,
      security_deposit: 500.0,
      lease_type: 1
    )
    LeaseTenant.create!(lease: other_lease, tenant: @tenant)

    # Let's add a debit (charge) to make other_lease's balance negative (-$100)
    # Since scheduled rents are generated, both leases already have scheduled rents.
    # We will manually create tenant payments to adjust balances.
    # other_lease balance:
    # scheduled rents are generated for 12 months.
    # Let's mock a charge on other_lease:
    TenantCharge.create!(
      lease: other_lease,
      amount: BigDecimal("20000.00"),
      charge_date: Date.current,
      description: "Custom charge",
      expense: @utility_expense
    )

    # Now other_lease has a more negative balance than @lease
    raw_source = read_eml_fixture("zelle-rent-payment.eml")
    processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
    email_record = processor.call

    assert_equal "matched", email_record.status
    assert_equal other_lease.id, email_record.tenant_payment.lease_id
  end
end
