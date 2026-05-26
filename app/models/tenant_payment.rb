class TenantPayment < ApplicationRecord
  belongs_to :lease
  belongs_to :user

  before_validation :assign_user_from_lease

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_date, presence: true
  validates :payment_method, presence: true
  validates :transaction_number, length: { maximum: 50 }, format: { with: /\A[a-zA-Z0-9_\-]*\z/, message: "must be alphanumeric with dashes or underscores" }, allow_blank: true
  validates :transaction_number, uniqueness: { scope: [ :user_id, :payment_method ] }, allow_blank: true
  validate :user_matches_lease_owner

  private
    def assign_user_from_lease
      self.user ||= lease.rental_property.user if lease&.rental_property
    end

    def user_matches_lease_owner
      return unless user_id && lease&.rental_property&.user_id

      if user_id != lease.rental_property.user_id
        errors.add(:user, "must match the lease owner")
      end
    end
end
