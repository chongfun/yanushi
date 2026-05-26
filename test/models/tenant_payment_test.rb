require "test_helper"

class TenantPaymentTest < ActiveSupport::TestCase
  test "valid tenant payment" do
    tp = TenantPayment.new(
      lease: leases(:one),
      amount: 1000.00,
      payment_date: Date.current,
      payment_method: "check"
    )
    assert tp.valid?
  end

  test "invalid without amount" do
    tp = TenantPayment.new(
      lease: leases(:one),
      payment_date: Date.current,
      payment_method: "check"
    )
    assert_not tp.valid?
  end

  test "invalid with non-positive amount" do
    tp = TenantPayment.new(
      lease: leases(:one),
      amount: 0,
      payment_date: Date.current,
      payment_method: "check"
    )
    assert_not tp.valid?
  end

  test "invalid without payment_date" do
    tp = TenantPayment.new(
      lease: leases(:one),
      amount: 1000.00,
      payment_method: "check"
    )
    assert_not tp.valid?
  end

  test "invalid without payment_method" do
    tp = TenantPayment.new(
      lease: leases(:one),
      amount: 1000.00,
      payment_date: Date.current
    )
    assert_not tp.valid?
  end

  test "assigns user from lease" do
    tp = TenantPayment.new(
      lease: leases(:one),
      amount: 1000.00,
      payment_date: Date.current,
      payment_method: "check"
    )

    assert tp.valid?
    assert_equal users(:one), tp.user
  end

  test "allows same transaction number for different users" do
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)
    other_lease = Lease.create!(
      rental_property: other_property,
      commencement_date: Date.current,
      annual_rental_amount: 12000,
      lease_type: :term
    )

    TenantPayment.create!(
      lease: leases(:one),
      amount: 500,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "SHARED123"
    )

    payment = TenantPayment.new(
      lease: other_lease,
      amount: 500,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "SHARED123"
    )

    assert payment.valid?
  end

  test "rejects duplicate transaction number for same user and payment method" do
    TenantPayment.create!(
      lease: leases(:one),
      amount: 500,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "DUPLICATE123"
    )

    payment = TenantPayment.new(
      lease: leases(:one),
      amount: 500,
      payment_date: Date.current,
      payment_method: "zelle",
      transaction_number: "DUPLICATE123"
    )

    assert_not payment.valid?
  end
end
