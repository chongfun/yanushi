require "test_helper"

class TenantChargeTest < ActiveSupport::TestCase
  test "valid tenant charge" do
    tc = TenantCharge.new(
      lease: leases(:one),
      expense: expenses(:one),
      amount: 250.00,
      charge_date: Date.current
    )
    assert tc.valid?
  end

  test "invalid without amount" do
    tc = TenantCharge.new(
      lease: leases(:one),
      expense: expenses(:one),
      charge_date: Date.current
    )
    assert_not tc.valid?
  end

  test "invalid with non-positive amount" do
    tc = TenantCharge.new(
      lease: leases(:one),
      expense: expenses(:one),
      amount: -5,
      charge_date: Date.current
    )
    assert_not tc.valid?
  end

  test "invalid without charge_date" do
    tc = TenantCharge.new(
      lease: leases(:one),
      expense: expenses(:one),
      amount: 250.00
    )
    assert_not tc.valid?
  end
end
