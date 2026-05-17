class NotificationsController < ApplicationController
  def index
    @notifications = Current.user.notifications.order(created_at: :desc)
  end

  def mark_read
    notification = Current.user.notifications.find(params[:id])
    notification.update!(read: true)
    redirect_back fallback_location: notifications_path, notice: "Notification marked as read."
  end

  def mark_all_read
    Current.user.notifications.unread.update_all(read: true)
    redirect_back fallback_location: notifications_path, notice: "All notifications marked as read."
  end
end
