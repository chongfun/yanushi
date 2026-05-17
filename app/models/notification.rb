class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :payment_email, optional: true

  enum :notification_type, {
    payment_unmatched: "payment_unmatched",
    payment_error:     "payment_error"
  }

  validates :title, :notification_type, presence: true

  scope :unread, -> { where(read: false) }
end
