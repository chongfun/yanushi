require "test_helper"

class RentalPropertiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @rental_property = rental_properties(:one)
  end

  test "should get index" do
    get rental_properties_url
    assert_response :success
  end

  test "should get new" do
    get new_rental_property_url
    assert_response :success
  end

  test "should create rental_property" do
    assert_difference("RentalProperty.count") do
      post rental_properties_url, params: { rental_property: { address: @rental_property.address, property_type: @rental_property.property_type, square_footage: @rental_property.square_footage, user_id: @rental_property.user_id } }
    end

    assert_redirected_to rental_property_url(RentalProperty.last)
  end

  test "should show rental_property" do
    get rental_property_url(@rental_property)
    assert_response :success
  end

  test "should get edit" do
    get edit_rental_property_url(@rental_property)
    assert_response :success
  end

  test "should update rental_property" do
    patch rental_property_url(@rental_property), params: { rental_property: { address: @rental_property.address, property_type: @rental_property.property_type, square_footage: @rental_property.square_footage, user_id: @rental_property.user_id } }
    assert_redirected_to rental_property_url(@rental_property)
  end

  test "should destroy " do
    assert_difference("RentalProperty.count", -1) do
      delete rental_property_url(@rental_property)
    end

    assert_redirected_to rental_properties_url
  end
end
