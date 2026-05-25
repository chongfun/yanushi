require "test_helper"

class LeasesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @lease = leases(:one)
  end

  test "should get index" do
    get leases_url
    assert_response :success
  end

  test "should get new" do
    get new_lease_url
    assert_response :success
  end

  test "should create lease" do
    assert_difference("Lease.count") do
      post leases_url, params: { lease: { annual_rental_amount: @lease.annual_rental_amount, commencement_date: @lease.commencement_date, late_period_days: @lease.late_period_days, lease_type: @lease.lease_type, rental_property_id: @lease.rental_property_id, termination_date: @lease.termination_date } }
    end

    assert_redirected_to lease_url(Lease.last)
  end

  test "should show lease" do
    get lease_url(@lease)
    assert_response :success
  end

  test "should get edit" do
    get edit_lease_url(@lease)
    assert_response :success
  end

  test "should update lease" do
    patch lease_url(@lease), params: { lease: { annual_rental_amount: @lease.annual_rental_amount, commencement_date: @lease.commencement_date, late_period_days: @lease.late_period_days, lease_type: @lease.lease_type, rental_property_id: @lease.rental_property_id, termination_date: @lease.termination_date } }
    assert_redirected_to lease_url(@lease)
  end

  test "should destroy" do
    assert_difference("Lease.count", -1) do
      delete lease_url(@lease)
    end

    assert_redirected_to leases_url
  end

  test "should not create lease with other user's property" do
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)

    assert_no_difference("Lease.count") do
      post leases_url, params: { lease: { annual_rental_amount: 10000, commencement_date: Date.current, lease_type: "term", rental_property_id: other_property.id } }
      assert_response :not_found
    end
  end

  test "should not update lease to other user's property" do
    other_user = users(:two)
    other_property = RentalProperty.create!(user: other_user, address: "999 Other St", property_type: :other)

    patch lease_url(@lease), params: { lease: { rental_property_id: other_property.id } }
    assert_response :not_found
  end
end
