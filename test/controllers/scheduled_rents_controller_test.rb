require "test_helper"

class ScheduledRentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @scheduled_rent = scheduled_rents(:one)
  end

  test "should get index" do
    get scheduled_rents_url
    assert_response :success
  end

  test "should get new" do
    get new_scheduled_rent_url
    assert_response :success
  end

  test "should create scheduled_rent" do
    assert_difference("ScheduledRent.count") do
      post scheduled_rents_url, params: { scheduled_rent: { expected_amount: @scheduled_rent.expected_amount, expected_due_date: @scheduled_rent.expected_due_date, lease_id: @scheduled_rent.lease_id } }
    end

    assert_redirected_to scheduled_rent_url(ScheduledRent.last)
  end

  test "should show scheduled_rent" do
    get scheduled_rent_url(@scheduled_rent)
    assert_response :success
  end

  test "should get edit" do
    get edit_scheduled_rent_url(@scheduled_rent)
    assert_response :success
  end

  test "should update scheduled_rent" do
    patch scheduled_rent_url(@scheduled_rent), params: { scheduled_rent: { expected_amount: @scheduled_rent.expected_amount, expected_due_date: @scheduled_rent.expected_due_date, lease_id: @scheduled_rent.lease_id } }
    assert_redirected_to scheduled_rent_url(@scheduled_rent)
  end

  test "should destroy " do
    assert_difference("ScheduledRent.count", -1) do
      delete scheduled_rent_url(@scheduled_rent)
    end

    assert_redirected_to scheduled_rents_url
  end
end
