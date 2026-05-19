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
end
