require "test_helper"

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
    @notification = Notification.create!(
      user: @user,
      title: "Test",
      notification_type: :payment_unmatched,
      read: false
    )
  end

  test "should get index" do
    get notifications_url
    assert_response :success
  end

  test "should mark notification as read" do
    post mark_read_notification_url(@notification)
    assert_redirected_to notifications_url
    assert @notification.reload.read?
  end

  test "should mark all notifications as read" do
    Notification.create!(user: @user, title: "Test 2", notification_type: :payment_unmatched, read: false)

    post mark_all_read_notifications_url
    assert_redirected_to notifications_url
    assert_equal 0, Notification.where(user: @user, read: false).count
  end
end
