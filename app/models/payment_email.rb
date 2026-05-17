class PaymentEmail < ApplicationRecord
  belongs_to :user
  belongs_to :rent_payment,    optional: true
  belongs_to :utility_payment, optional: true

  enum :status, {
    pending:          "pending",
    matched_rent:     "matched_rent",
    matched_utility:  "matched_utility",
    unmatched:        "unmatched",
    error:            "error"
  }

  validates :message_id, presence: true, uniqueness: { scope: :user_id }
end
