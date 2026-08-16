class Account < ApplicationRecord
  belongs_to :user
  has_many :postings, dependent: :restrict_with_error

  ACCOUNT_TYPES = %w[
    asset
    liability
    equity
    income
    expense
  ].freeze

  enum :account_type, ACCOUNT_TYPES.index_by(&:itself), prefix: false, validate: true

  validates :key, presence: true,
                  uniqueness: { scope: :user_id, case_sensitive: false },
                  format: { with: /\A[a-z0-9_]+\z/, message: "must contain only lowercase letters, numbers, and underscores" }
  validates :name, presence: true
  validates :account_type, presence: true
  validate :identity_fields_immutable, on: :update

  normalizes :key, with: ->(k) { k.strip.downcase }
  normalizes :name, with: ->(n) { n.strip }

  def accounting_user
    user
  end

  private

    def identity_fields_immutable
      errors.add(:user_id, "cannot be changed") if user_id_changed?
      errors.add(:key, "cannot be changed") if key_changed?
      errors.add(:account_type, "cannot be changed") if account_type_changed?
    end
end
