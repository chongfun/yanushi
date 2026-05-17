require "test_helper"

class NotificationTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "validates presence of title and notification_type" do
    notification = Notification.new(user: @user)
    assert_not notification.valid?
    assert_includes notification.errors[:title], "can't be blank"
    assert_includes notification.errors[:notification_type], "can't be blank"
  end

  test "unread scope returns only unread notifications" do
    Notification.create!(user: @user, title: "Notification 1", notification_type: :payment_unmatched, read: false)
    Notification.create!(user: @user, title: "Notification 2", notification_type: :payment_unmatched, read: true)

    assert_equal 1, Notification.unread.count
  end
end
