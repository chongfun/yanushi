class Property < ApplicationRecord
  belongs_to :user
  has_many :rentable_units, dependent: :destroy
  has_many :tenancies, through: :rentable_units
  has_many :expenses, dependent: :restrict_with_error
  has_many :charges, through: :tenancies
  has_many :receipts, through: :tenancies
  has_many :security_deposit_transactions, through: :tenancies
  has_many :postings, class_name: "Posting", dependent: :restrict_with_error
  has_many :accounting_postings, class_name: "Posting", dependent: :restrict_with_error
  has_many :tax_profiles, class_name: "PropertyTaxProfile", dependent: :destroy

  ASSET_TYPES = %w[
    single_family
    multifamily
    commercial
    mixed_use
    land
    other
  ].freeze

  enum :asset_type, ASSET_TYPES.index_by(&:itself), prefix: false, validate: true

  validates :address, presence: true, uniqueness: { scope: :user_id, case_sensitive: false }
  validates :asset_type, presence: true
  validates :square_footage, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  normalizes :address, with: ->(a) { a.strip }

  def financial_items(*args, year: nil)
    target_year = year || args.first || Date.current.year
    Accounting::PropertyLedgerQuery.call(property: self, year: target_year)
  end

  def active_years(additional_years = [])
    Accounting::ActiveYearsQuery.call(property: self, additional_years: additional_years)
  end

  def accounting_activity(from: nil, through: nil, year: nil)
    Accounting::PropertyLedgerQuery.call(property: self, from: from, through: through, year: year)
  end

  def accounting_summary(from: nil, through: nil, year: nil)
    Accounting::PropertySummaryQuery.call(property: self, from: from, through: through, year: year)
  end

  def schedule_e_summary(*args, year: nil)
    target_year = year || args.first || Date.current.year
    TaxReporting::ScheduleEQuery.call(property: self, tax_year: target_year)
  end

  def accounting_user
    user
  end

  def tax_profile_for(year)
    tax_profiles.find_by(tax_year: year)
  end
end
