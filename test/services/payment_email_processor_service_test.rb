require "test_helper"
require "mail"

class PaymentEmailProcessorServiceTest < ActiveSupport::TestCase
  setup do
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

    # 7. Use the automatically generated scheduled rents
    @scheduled_rent_1 = @lease.scheduled_rents.order(:due_date).first
    @scheduled_rent_2 = @lease.scheduled_rents.order(:due_date).second
  end

  def read_eml_fixture(filename)
    File.read(Rails.root.join("test/fixtures/emails", filename))
  end

  test "routes Chase Zelle utility payment exactly to utility expense" do
    raw_source = read_eml_fixture("zelle-utility-payment.eml")

    assert_difference -> { UtilityPayment.count } => 1, -> { RentPayment.count } => 0 do
      processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
      email_record = processor.call

      assert_equal "matched_utility", email_record.status
      assert_not_nil email_record.utility_payment
      assert_equal @utility_expense.id, email_record.utility_payment.expense_id
      assert_equal BigDecimal("240.92"), email_record.utility_payment.amount
    end
  end

  test "routes Chase Zelle rent payment to earliest unpaid scheduled rent" do
    raw_source = read_eml_fixture("zelle-rent-payment.eml")

    assert_difference -> { RentPayment.count } => 1, -> { UtilityPayment.count } => 0 do
      processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
      email_record = processor.call

      assert_equal "matched_rent", email_record.status
      assert_not_nil email_record.rent_payment
      assert_equal @scheduled_rent_1.id, email_record.rent_payment.scheduled_rent_id
      assert_equal BigDecimal("1200.00"), email_record.rent_payment.amount
    end
  end

  test "routes Venmo rent payment to earliest unpaid scheduled rent using Samantha Sanchez alias" do
    # Add Samantha Sanchez alias to the tenant
    @tenant.tenant_aliases.create!(name: "samantha sanchez")
    raw_source = read_eml_fixture("venmo-rent-payment.eml")

    assert_difference -> { RentPayment.count } => 1, -> { UtilityPayment.count } => 0 do
      processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
      email_record = processor.call

      assert_equal "matched_rent", email_record.status
      assert_not_nil email_record.rent_payment
      assert_equal @scheduled_rent_1.id, email_record.rent_payment.scheduled_rent_id
      assert_equal BigDecimal("1000.00"), email_record.rent_payment.amount
    end
  end

  test "marks email unmatched and creates in-app notification when tenant cannot be found" do
    raw_source = read_eml_fixture("venmo-rent-payment.eml") # No tenant "samantha sanchez" exists

    assert_no_difference -> { RentPayment.count } do
      assert_difference -> { Notification.count } => 1 do
        processor = PaymentEmailProcessorService.new(raw_source: raw_source, user: @user)
        email_record = processor.call

        assert_equal "unmatched", email_record.status
        assert_nil email_record.rent_payment
        assert_nil email_record.utility_payment
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
    assert_equal "matched_rent", email_record.status

    # Process again - should skip/be nil
    assert_no_difference -> { RentPayment.count } do
      second_record = processor.call
      assert_nil second_record
    end
  end
end
