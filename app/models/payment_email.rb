class PaymentEmail < ApplicationRecord
  belongs_to :user
  belongs_to :tenant_payment,    optional: true

  enum :status, {
    pending:          "pending",
    matched:          "matched",
    unmatched:        "unmatched",
    error:            "error"
  }

  validates :message_id, presence: true, uniqueness: { scope: :user_id }
end
