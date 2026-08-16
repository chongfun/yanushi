class TenantPayment < ApplicationRecord
  belongs_to :tenancy
  belongs_to :user

  before_validation :assign_user_from_tenancy

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_date, presence: true
  validates :payment_method, presence: true
  validates :transaction_number, length: { maximum: 50 }, format: { with: /\A[a-zA-Z0-9_\-]*\z/, message: "must be alphanumeric with dashes or underscores" }, allow_blank: true
  validates :transaction_number, uniqueness: { scope: %i[user_id payment_method] }, allow_blank: true
  validate :user_matches_tenancy_owner

  has_many :journal_entries, as: :source, dependent: :restrict_with_error

  validate :prevent_mutation_after_creation, on: :update
  before_destroy :prevent_destroy

  def accounting_user
    user || tenancy&.property&.user
  end

  private

    def prevent_mutation_after_creation
      errors.add(:base, "Tenant payments are immutable once recorded.")
    end

    def prevent_destroy
      errors.add(:base, "Tenant payments cannot be destroyed once recorded.")
      throw(:abort)
    end

    def assign_user_from_tenancy
      if (prop = tenancy&.property) && (prop_user = prop.user)
        self.user ||= prop_user
      end
    end

    def user_matches_tenancy_owner
      return unless user_id && (prop = tenancy&.property)

      if user_id != prop.user_id
        errors.add(:user, "must match the tenancy owner")
      end
    end
end
