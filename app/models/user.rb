class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :properties, dependent: :destroy
  has_many :rentable_units, through: :properties
  has_many :tenancies, through: :rentable_units
  has_many :expenses, through: :properties
  has_many :charges, through: :tenancies
  has_many :receipts, dependent: :restrict_with_error
  has_many :parties, dependent: :destroy
  has_many :imported_transactions, dependent: :destroy
  has_many :source_documents, dependent: :destroy
  has_many :accounts, dependent: :restrict_with_error
  has_many :journal_entries, dependent: :restrict_with_error

  validates :email, presence: true, uniqueness: true
  validates :password_digest, presence: true

  normalizes :email, with: ->(e) { e.strip.downcase }

  after_create :provision_chart_of_accounts

  def accounting_user
    self
  end

  private

    def provision_chart_of_accounts
      Accounting::ChartOfAccounts.ensure_for(self)
    end
end
