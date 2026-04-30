require "test_helper"

class DashboardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
  end

  test "should get index" do
    get dashboards_index_url
    assert_response :success
  end
end
