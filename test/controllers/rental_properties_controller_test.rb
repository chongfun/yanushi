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

  test "should destroy" do
    assert_difference("RentalProperty.count", -1) do
      delete rental_property_url(@rental_property)
    end

    assert_redirected_to rental_properties_url
  end

  test "should download schedule_e_pdf for available year" do
    # 2025 is available in app/assets/pdfs
    get schedule_e_pdf_rental_property_url(@rental_property, year: 2025)
    assert_response :success
    assert_equal "application/pdf", response.content_type
    assert_match /attachment/, response.headers["Content-Disposition"]
  end

  test "should redirect and show alert for missing schedule_e_pdf" do
    # 2026 is missing
    get schedule_e_pdf_rental_property_url(@rental_property, year: 2026)
    assert_redirected_to rental_property_path(@rental_property, year: 2026)
    assert_equal "No Schedule E PDF template found for year 2026", flash[:alert]
  end

  test "should get schedule_e modal" do
    get schedule_e_rental_property_url(@rental_property)
    assert_response :success
  end
end
